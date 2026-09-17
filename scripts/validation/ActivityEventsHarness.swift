import AppKit
import CodexIntegration
import Diagnostics
import SQLite3

/// Isolated release benchmark: synthetic logs, no preferences, overlay, usage RPC,
/// or writes to the user's Codex home. Compile the same source against both builds.
@main
@MainActor
struct ActivityEventsHarness {
    static func main() async throws {
        let seconds = Double(ProcessInfo.processInfo.environment["ACTIVITY_SECONDS"] ?? "60") ?? 60
        let burst = CommandLine.arguments.contains("--burst")
        let trial = CommandLine.arguments.last ?? "1"
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.start()
        try await Task.sleep(for: .seconds(2))
        let countsBefore = try fixture.counts()
        let before = try ProcessResourceSnapshot.read()
        let started = ContinuousClock.now
        var latencies: [Double] = []
        if burst {
            for _ in 0..<3 {
                for working in [true, false] {
                    let transitionStart = ContinuousClock.now
                    try fixture.append(working ? "task_started" : "task_complete")
                    try await fixture.waitFor(working: working)
                    latencies.append(transitionStart.duration(to: .now).seconds)
                    try await Task.sleep(for: .milliseconds(250))
                }
            }
        } else {
            try await Task.sleep(for: .seconds(seconds))
        }
        let elapsed = started.duration(to: .now).seconds
        let after = try ProcessResourceSnapshot.read()
        let countsAfter = try fixture.counts()
        #if LEGACY_ACTIVITY
        let implementation = "baseline-polling"
        #else
        let implementation = "file-events"
        #endif
        let record: [String: Any] = [
            "implementation": implementation, "scenario": burst ? "burst" : "idle", "trial": trial,
            "elapsedSeconds": elapsed,
            "cpuPercent": Double(after.userTimeNanoseconds - before.userTimeNanoseconds
                + after.systemTimeNanoseconds - before.systemTimeNanoseconds) / 1e9 / elapsed * 100,
            "interruptWakeups": after.interruptWakeups - before.interruptWakeups,
            "packageIdleWakeups": after.packageIdleWakeups - before.packageIdleWakeups,
            "physicalFootprintBytes": after.physicalFootprintBytes,
            "metadataChecks": countsAfter.metadata - countsBefore.metadata,
            "activityReads": countsAfter.reads - countsBefore.reads,
            "bytesRead": countsAfter.bytes - countsBefore.bytes,
            "latencySeconds": latencies,
            "finalWorking": fixture.latest?.isWorking ?? false,
            "diagnosticsEnabled": true, "sessionFiles": 256
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
    }
}

@MainActor
private final class Fixture {
    let root: URL
    let logs: URL
    let recorder: DiagnosticRecorder
    var latest: CodexActivitySnapshot?
    var consumer: Task<Void, Never>?
    var writer: FileHandle?
    #if !LEGACY_ACTIVITY
    let observation: CodexActivityObservation
    #endif

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("activity-benchmark-\(UUID())").resolvingSymlinksInPath()
        logs = root.appendingPathExtension("diagnostics")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        recorder = DiagnosticRecorder(directory: logs, enabled: true)
        #if !LEGACY_ACTIVITY
        observation = CodexActivityObservation(diagnostics: recorder, codexHome: root)
        #endif
        var db: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("state_1.sqlite").path, &db) == SQLITE_OK else { throw HarnessError.database }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "CREATE TABLE threads (rollout_path TEXT, archived INTEGER, updated_at INTEGER)", nil, nil, nil) == SQLITE_OK else { throw HarnessError.database }
        for index in 0..<256 {
            try event("task_complete").write(to: root.appendingPathComponent("sessions/\(index).jsonl"))
            guard sqlite3_exec(db, "INSERT INTO threads VALUES ('\(index).jsonl', 0, \(index))", nil, nil, nil) == SQLITE_OK else { throw HarnessError.database }
        }
    }

    func start() async throws {
        #if LEGACY_ACTIVITY
        let reader = CodexActivityReader(diagnostics: recorder, codexHome: root)
        consumer = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot = await reader.read()
                guard !Task.isCancelled else { return }
                self?.latest = snapshot
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        #else
        let stream = observation.snapshots()
        consumer = Task { [weak self] in
            for await snapshot in stream { self?.latest = snapshot }
        }
        #endif
        try await waitFor(working: false)
    }

    func waitFor(working: Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while latest?.isWorking != working || latest?.isAvailable != true {
            if ContinuousClock.now >= deadline { throw HarnessError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func append(_ type: String) throws {
        if writer == nil { writer = try FileHandle(forWritingTo: root.appendingPathComponent("sessions/0.jsonl")) }
        let handle = writer!
        try handle.seekToEnd(); try handle.write(contentsOf: event(type))
    }

    func event(_ type: String) -> Data {
        Data("{\"type\":\"event_msg\",\"timestamp\":\"\(Date().ISO8601Format())\",\"payload\":{\"type\":\"\(type)\"}}\n".utf8)
    }

    func counts() throws -> (metadata: Int, reads: Int, bytes: Int) {
        recorder.flush()
        var metadata = 0, reads = 0, bytes = 0
        for url in try FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil) where url.pathExtension == "jsonl" {
            for line in try Data(contentsOf: url).split(separator: 10) {
                guard let record = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let fields = record["fields"] as? [String: Any], fields["operation"] as? String == "activityRead",
                      fields["phase"] as? String == "end" else { continue }
                reads += 1; metadata += fields["metadataChecks"] as? Int ?? 0; bytes += fields["bytesRead"] as? Int ?? 0
            }
        }
        return (metadata, reads, bytes)
    }

    func close() {
        try? writer?.close()
        consumer?.cancel()
        #if !LEGACY_ACTIVITY
        observation.stop()
        #endif
        recorder.shutdown()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: logs)
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
private enum HarnessError: Error { case database, timeout }
