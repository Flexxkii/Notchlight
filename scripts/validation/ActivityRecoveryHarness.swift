import AppKit
import CodexIntegration
import Diagnostics
import SQLite3

/// Synthetic release workloads. Never reads or writes the user's Codex data.
@main
@MainActor
struct ActivityRecoveryHarness {
    static func main() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.close() }
        let wal = CommandLine.arguments.contains("--wal")
        let trial = CommandLine.arguments.last ?? "1"
        var extra: [String: Any] = [:]
        if wal {
            try await fixture.startWatching()
            try fixture.sql("PRAGMA journal_mode=WAL")
            try await fixture.waitForMissingWAL()
        } else {
            try fixture.prepareLargeLog()
            try await fixture.parse() // Warm filesystem/runtime caches outside measurement.
        }
        let queriesBefore = try fixture.queryCount()
        let before = try ProcessResourceSnapshot.read()
        let start = ContinuousClock.now
        if wal {
            try await Task.sleep(for: .seconds(12))
        } else {
            for _ in 0..<5 { try await fixture.parse() }
        }
        let elapsed = start.duration(to: .now).seconds
        let after = try ProcessResourceSnapshot.read()
        let cpu = Double(after.userTimeNanoseconds - before.userTimeNanoseconds
            + after.systemTimeNanoseconds - before.systemTimeNanoseconds) / 1e9
        extra["databaseQueries"] = try fixture.queryCount() - queriesBefore
        extra["scenario"] = wal ? "cached-missing-wal" : "large-log"
        extra["trial"] = trial
        extra["elapsedSeconds"] = elapsed
        extra["cpuSeconds"] = cpu
        extra["interruptWakeups"] = after.interruptWakeups - before.interruptWakeups
        extra["physicalFootprintBytes"] = after.physicalFootprintBytes
        extra["iterations"] = wal ? 0 : 5
        extra["inputBytes"] = fixture.inputBytes
        extra["diagnosticsEnabled"] = wal
        if wal {
            guard fixture.latest?.isAvailable == true, fixture.latest?.isWorking == false else {
                throw RecoveryError.incorrectSnapshot
            }
            // Recover through a real WAL event, then consume a held-open append.
            let recoveryStart = ContinuousClock.now
            try fixture.openWALWriter()
            try fixture.appendStarted()
            try await fixture.waitForWorking()
            extra["recoverySeconds"] = recoveryStart.duration(to: .now).seconds
        }
        try FileHandle.standardOutput.write(contentsOf:
            JSONSerialization.data(withJSONObject: extra, options: [.sortedKeys]) + Data([10]))
    }
}

@MainActor
private final class RecoveryFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("activity-recovery-\(UUID())")
        .resolvingSymlinksInPath()
    let recorder: DiagnosticRecorder
    let observation: CodexActivityObservation
    var consumer: Task<Void, Never>?
    var latest: CodexActivitySnapshot?
    var database: OpaquePointer?
    var writer: FileHandle?
    var inputBytes = 0
    var log: URL { root.appendingPathComponent("sessions/0.jsonl") }
    var logs: URL { root.appendingPathComponent("diagnostics") }

    init() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        recorder = DiagnosticRecorder(directory: root.appendingPathComponent("diagnostics"), enabled: false)
        observation = CodexActivityObservation(diagnostics: recorder, codexHome: root)
        try Self.event("task_complete").write(to: log)
        try sql("CREATE TABLE threads (rollout_path TEXT, archived INTEGER, updated_at INTEGER); INSERT INTO threads VALUES ('0.jsonl', 0, 1)")
    }

    func sql(_ text: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("state_1.sqlite").path, &db) == SQLITE_OK else { throw RecoveryError.database }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK else { throw RecoveryError.database }
    }

    func prepareLargeLog() throws {
        let stamp = Date().ISO8601Format(.iso8601(timeZone: .gmt, includingFractionalSeconds: true))
        let content = String(repeating: "synthetic tool output ", count: 780)
        var data = Self.event("task_started")
        for index in 0..<480 {
            let type = index.isMultiple(of: 4) ? "response_item" : "event_msg"
            data.append(Data("{\"timestamp\":\"\(stamp)\",\"type\":\"\(type)\",\"payload\":{\"type\":\"agent_message\",\"message\":\"\(content)\"}}\n".utf8))
            if index.isMultiple(of: 16) { data.append(Self.event("token_count")) }
        }
        data.append(Self.event("task_complete"))
        inputBytes = data.count
        guard inputBytes < 8 * 1024 * 1024 else { throw RecoveryError.oversizedFixture }
        try data.write(to: log)
    }

    func parse() async throws {
        let launch = Date().addingTimeInterval(-60)
        let reader = CodexActivityReader(codexHome: root, desktopLaunchDateProvider: { launch })
        let snapshot = await reader.read()
        guard snapshot.isAvailable, !snapshot.isWorking else { throw RecoveryError.incorrectSnapshot }
    }

    func startWatching() async throws {
        recorder.setEnabled(true)
        let stream = observation.snapshots()
        consumer = Task { [weak self] in
            for await value in stream { self?.latest = value }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while latest?.isAvailable != true {
            if ContinuousClock.now >= deadline { throw RecoveryError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func waitForMissingWAL() async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while try !queryRecords().contains(where: { $0["errorCategory"] as? String == "walUnavailable" }) {
            if ContinuousClock.now >= deadline { throw RecoveryError.timeout }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func openWALWriter() throws {
        guard sqlite3_open(root.appendingPathComponent("state_1.sqlite").path, &database) == SQLITE_OK,
              sqlite3_exec(database, "UPDATE threads SET updated_at=2", nil, nil, nil) == SQLITE_OK else { throw RecoveryError.database }
    }

    func appendStarted() throws {
        writer = try FileHandle(forWritingTo: log)
        try writer?.seekToEnd()
        try writer?.write(contentsOf: Self.event("task_started"))
    }

    func waitForWorking() async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while latest?.isWorking != true {
            if ContinuousClock.now >= deadline { throw RecoveryError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func queryCount() throws -> Int { try queryRecords().count }
    func queryRecords() throws -> [[String: Any]] {
        guard recorder.isEnabled else { return [] }
        recorder.flush()
        return try FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil).flatMap { url in
            try Data(contentsOf: url).split(separator: 10).compactMap { line in
                let record = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
                guard let fields = record?["fields"] as? [String: Any], fields["operation"] as? String == "databaseQuery",
                      fields["phase"] as? String == "end" else { return nil }
                return fields
            }
        }
    }

    func close() {
        consumer?.cancel(); observation.stop(); recorder.shutdown()
        try? writer?.close()
        if let database { sqlite3_close(database) }
        try? FileManager.default.removeItem(at: root)
    }

    static func event(_ type: String) -> Data {
        Data("{\"timestamp\":\"\(Date().ISO8601Format())\",\"type\":\"event_msg\",\"payload\":{\"type\":\"\(type)\"}}\n".utf8)
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
private enum RecoveryError: Error { case database, timeout, incorrectSnapshot, oversizedFixture }
