import Foundation
import Testing
import SQLite3
import Diagnostics
@testable import CodexIntegration

struct CodexActivityTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    @Test("a recent task lifecycle is reported as active")
    func recentActiveTask() {
        let state = state(lifecycle: .active, age: 2)
        let snapshot = CodexActivityClassifier.snapshot(states: [state], sampledAt: now, sourceAvailable: true)
        #expect(snapshot.isWorking)
        #expect(snapshot.activeTaskCount == 1)
        #expect(snapshot.isAvailable)
        #expect(snapshot.detail == "Codex active (1 task)")
    }

    @Test("completed sessions stay idle even when their file is recent")
    func completedTaskIsNotAFalsePositive() {
        let state = state(lifecycle: .idle, age: 1)
        let snapshot = CodexActivityClassifier.snapshot(states: [state], sampledAt: now, sourceAvailable: true)
        #expect(!snapshot.isWorking)
        #expect(snapshot.activeTaskCount == 0)
        #expect(snapshot.isAvailable)
        #expect(snapshot.detail == "Codex idle")
    }

    @Test("an unresolved recent file is unavailable rather than falsely active")
    func unknownLifecycleIsUnavailable() {
        let state = state(lifecycle: .unknown, age: 4)
        let snapshot = CodexActivityClassifier.snapshot(states: [state], sampledAt: now, sourceAvailable: true)
        #expect(!snapshot.isWorking)
        #expect(snapshot.activeTaskCount == 0)
        #expect(!snapshot.isAvailable)
    }

    @Test("stale unresolved activity does not keep the border glowing")
    func staleActivityIsIgnored() {
        let state = state(lifecycle: .active, age: 16 * 60)
        let snapshot = CodexActivityClassifier.snapshot(states: [state], sampledAt: now, sourceAvailable: true)
        #expect(!snapshot.isWorking)
        #expect(snapshot.activeTaskCount == 0)
        #expect(!snapshot.isAvailable)
        #expect(snapshot.detail == "Codex activity unavailable")
    }

    @Test("touching a stale log without a lifecycle event does not revive it")
    func staleLifecycleIsNotRevivedByFileMtime() {
        var state = state(lifecycle: .active, age: 1)
        state.lastLifecycleAt = now.addingTimeInterval(-16 * 60)
        let snapshot = CodexActivityClassifier.snapshot(states: [state], sampledAt: now, sourceAvailable: true)
        #expect(!snapshot.isWorking)
        #expect(!snapshot.isAvailable)
    }

    @Test("lifecycle parser preserves partial lines and recognizes interruption")
    func parserHandlesPartialLinesAndInterruption() throws {
        var state = state(lifecycle: .unknown, age: 0)
        let started = event(type: "task_started", at: now.addingTimeInterval(-4))
        let split = started.count / 2
        _ = CodexActivityParser.consume(data: started.prefix(split), state: &state, launchDate: nil)
        #expect(state.lifecycle == .unknown)
        _ = CodexActivityParser.consume(data: started.dropFirst(split), state: &state, launchDate: nil)
        #expect(state.lifecycle == .active)

        let interrupted = event(type: "turn_aborted", at: now.addingTimeInterval(-1))
        _ = CodexActivityParser.consume(data: interrupted, state: &state, launchDate: nil)
        #expect(state.lifecycle == .idle)
        #expect(state.lastHeartbeatAt == nil)
    }

    @Test("events before the desktop launch are ignored")
    func parserHonorsLaunchDate() {
        var state = state(lifecycle: .unknown, age: 0)
        let event = event(type: "task_started", at: now.addingTimeInterval(-10))
        _ = CodexActivityParser.consume(data: event, state: &state, launchDate: now.addingTimeInterval(-5))
        #expect(state.lifecycle == .unknown)
    }

    @Test("valid non-lifecycle JSON is parsed but not counted as a parse failure")
    func parserIgnoresValidNonLifecycleRecords() {
        var state = state(lifecycle: .unknown, age: 0)
        let result = CodexActivityParser.consume(data: Data("{\"type\":\"session_meta\"}\n".utf8), state: &state, launchDate: nil)
        #expect(result.parsedRecords == 1)
        #expect(result.parseFailures == 0)
        #expect(state.lifecycle == .unknown)
    }

    @Test("multiple active session paths are counted")
    func multipleActiveTasks() {
        let states = [state(lifecycle: .active, age: 3), state(lifecycle: .active, age: 30)]
        let snapshot = CodexActivityClassifier.snapshot(states: states, sampledAt: now, sourceAvailable: true)
        #expect(snapshot.isWorking)
        #expect(snapshot.activeTaskCount == 2)
        #expect(snapshot.detail == "Codex active (2 tasks)")
    }

    @Test("a missing metadata source is unavailable")
    func unavailableSource() {
        let snapshot = CodexActivityClassifier.snapshot(states: [], sampledAt: now, sourceAvailable: false)
        #expect(!snapshot.isWorking)
        #expect(snapshot.activeTaskCount == 0)
        #expect(!snapshot.isAvailable)
        #expect(snapshot.detail == "Codex activity unavailable")
    }

    @Test("activity reader emits bounded fixture telemetry")
    func fixtureTelemetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notchlight-activity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let active = sessions.appendingPathComponent("active.jsonl")
        let sampleNow = Date()
        let eventDate = ISO8601DateFormatter().string(from: sampleNow.addingTimeInterval(-1))
        let line = "{\"type\":\"event_msg\",\"timestamp\":\"\(eventDate)\",\"payload\":{\"type\":\"task_started\"}}\n"
        try Data((line + "{\"type\":\"session_meta\"}\nnot-json\n").utf8).write(to: active)
        try FileManager.default.createDirectory(at: sessions.appendingPathComponent("unreadable"), withIntermediateDirectories: true)
        let database = root.appendingPathComponent("state_1.sqlite")
        try createFixtureDatabase(at: database, paths: ["active.jsonl", "unreadable"])
        let logDirectory = root.appendingPathComponent("logs")
        let recorder = DiagnosticRecorder(directory: logDirectory, enabled: true)
        let reader = CodexActivityReader(diagnostics: recorder, codexHome: root, desktopLaunchDateProvider: { sampleNow.addingTimeInterval(-2) })
        let first = await reader.read()
        let second = await reader.read()
        recorder.flush()
        let files = try FileManager.default.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: nil)
        let log = try files.filter { $0.pathExtension == "jsonl" }.map { try String(contentsOf: $0) }.joined()
        #expect(first.isWorking)
        #expect(second.isWorking)
        #expect(log.contains("activityRead"))
        #expect(log.contains("bytesRead"))
        #expect(log.contains("parseFailures"))
        #expect(log.contains("unreadableFiles"))
        recorder.shutdown()
    }

    @Test("old files stay skipped across polls and resume at newly appended events", arguments: [false, true])
    func skippedOldFilesResumeFromEnd(afterTruncation: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notchlight-old-activity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let rollout = sessions.appendingPathComponent("old.jsonl")
        try createFixtureDatabase(at: root.appendingPathComponent("state_1.sqlite"), paths: ["old.jsonl"])
        let sampleNow = Date()
        let logDirectory = root.appendingPathComponent("logs")
        let recorder = DiagnosticRecorder(directory: logDirectory, enabled: true)
        defer { recorder.shutdown() }
        let reader = CodexActivityReader(diagnostics: recorder, codexHome: root,
                                        desktopLaunchDateProvider: { sampleNow.addingTimeInterval(-10) })

        if afterTruncation {
            var initial = event(type: "task_started", at: sampleNow.addingTimeInterval(-1))
            initial.append(Data(String(repeating: "{\"type\":\"session_meta\"}\n", count: 128).utf8))
            try initial.write(to: rollout)
            let active = await reader.read()
            #expect(active.isWorking)
        }

        let oldData = Data(String(repeating: "{\"type\":\"session_meta\"}\n", count: 32).utf8)
        try oldData.write(to: rollout)
        try FileManager.default.setAttributes([.modificationDate: sampleNow.addingTimeInterval(-60 * 60)],
                                              ofItemAtPath: rollout.path)
        for _ in 0..<3 {
            let idle = await reader.read()
            #expect(idle.isAvailable)
            #expect(!idle.isWorking)
        }

        let started = event(type: "task_started", at: Date().addingTimeInterval(-1))
        let stopped = event(type: "turn_aborted", at: Date())
        let handle = try FileHandle(forWritingTo: rollout)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: started)
        let active = await reader.read()
        #expect(active.isAvailable)
        #expect(active.activeTaskCount == 1)
        try handle.write(contentsOf: stopped)
        let idle = await reader.read()
        #expect(idle.isAvailable)
        #expect(!idle.isWorking)
        _ = await reader.read()

        recorder.flush()
        let files = try FileManager.default.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: nil)
        let records = try files.filter { $0.pathExtension == "jsonl" }.flatMap { url in
            try Data(contentsOf: url).split(separator: 10).map {
                try #require(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
            }
        }.sorted { ($0["sequence"] as? Int ?? 0) < ($1["sequence"] as? Int ?? 0) }
        let reads = records.compactMap { $0["fields"] as? [String: Any] }.filter {
            $0["operation"] as? String == "activityRead" && $0["phase"] as? String == "end"
        }.dropFirst(afterTruncation ? 1 : 0)
        // Assert actual I/O, not just idle classification: stale files used to
        // be read on the second poll even though their metadata was unchanged.
        #expect(reads.map { $0["bytesRead"] as? Int } == [0, 0, 0, started.count, stopped.count, 0])
        #expect(reads.map { $0["parsedRecords"] as? Int } == [0, 0, 0, 1, 1, 0])
        #expect(reads.allSatisfy { $0["parseFailures"] as? Int == 0 })
    }

    private func createFixtureDatabase(at url: URL, paths: [String]) throws {
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database, "CREATE TABLE threads (rollout_path TEXT, archived INTEGER, updated_at INTEGER);", nil, nil, nil) == SQLITE_OK)
        for (index, path) in paths.enumerated() {
            let sql = "INSERT INTO threads VALUES ('\(path)', 0, \(index));"
            #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        }
    }

    private func state(lifecycle: ActivityLifecycle, age: TimeInterval) -> ActivityFileState {
        let modifiedAt = now.addingTimeInterval(-age)
        var result = ActivityFileState(metadata: ActivityFileMetadata(
            path: "/tmp/codex-activity-test.jsonl",
            size: 128,
            modifiedAt: modifiedAt
        )).withLifecycle(lifecycle)
        if lifecycle == .active { result.lastLifecycleAt = modifiedAt }
        return result
    }

    private func event(type: String, at date: Date) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: date)
        return Data("{\"type\":\"event_msg\",\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"\(type)\"}}\n".utf8)
    }
}

private extension ActivityFileState {
    func withLifecycle(_ lifecycle: ActivityLifecycle) -> Self {
        var copy = self
        copy.lifecycle = lifecycle
        return copy
    }
}
