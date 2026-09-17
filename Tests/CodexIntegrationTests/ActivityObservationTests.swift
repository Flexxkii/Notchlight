import Foundation
import Darwin
import CoreServices
import SQLite3
import Testing
import Diagnostics
@testable import CodexIntegration

@Suite(.serialized)
@MainActor
struct ActivityObservationTests {
    @Test("unchanged files cause no polling or timestamp-only publications")
    func idleAndIncremental() async throws {
        let f = try Fixture(count: 256)
        defer { f.close() }
        try await f.start()
        let baseline = try f.reads()
        #expect(baseline.last?["metadataChecks"] as? Int == 256)
        try await Task.sleep(for: .milliseconds(180))
        #expect(try f.reads().count == baseline.count)
        #expect(f.values.count == 1)
        try f.append("task_started")
        f.emit()
        try await wait { f.values.last?.activeTaskCount == 1 }
        #expect(try f.reads().last?["metadataChecks"] as? Int == 1)
        let count = f.values.count
        try f.append("token_count")
        f.emit()
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.values.count == count)
        try f.append("turn_aborted")
        f.emit()
        try await wait { f.values.last?.isWorking == false }
        #expect(await f.desktop.calls == 1)
    }

    @Test("partial records, concurrent tasks, and completion keep exact counts")
    func lifecycle() async throws {
        let f = try Fixture(count: 2)
        defer { f.close() }
        try await f.start()
        let line = Fixture.event("task_started")
        try f.appendData(line.prefix(line.count / 2)); f.emit()
        try await Task.sleep(for: .milliseconds(70))
        #expect(f.values.last?.isWorking == false)
        try f.appendData(line.suffix(line.count - line.count / 2)); f.emit()
        try await wait { f.values.last?.activeTaskCount == 1 }
        try f.append("task_started", index: 1); f.emit(index: 1)
        try await wait { f.values.last?.activeTaskCount == 2 }
        try f.append("task_complete"); f.emit()
        try await wait { f.values.last?.activeTaskCount == 1 }
        try f.append("task_complete", index: 1); f.emit(index: 1)
        try await wait { f.values.last?.isWorking == false }
    }

    @Test("new nested file arriving before its catalog registration is discovered")
    func delayedCatalog() async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.start()
        let newFile = f.root.appendingPathComponent("sessions/2026/09/17/new.jsonl")
        try FileManager.default.createDirectory(at: newFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Fixture.event("task_started").write(to: newFile)
        f.watcher.emit(ActivityFileChanges(paths: [newFile.path]))
        try await Task.sleep(for: .milliseconds(120))
        #expect(f.values.last?.isWorking == false)
        try f.sql("INSERT INTO threads VALUES ('2026/09/17/new.jsonl', 0, 999)")
        f.watcher.emit(ActivityFileChanges(catalog: true))
        try await wait { f.values.last?.isWorking == true }
        try f.sql("UPDATE threads SET archived=1 WHERE updated_at=999")
        f.watcher.emit(ActivityFileChanges(catalog: true))
        try await wait { f.values.last?.isWorking == false }
    }

    @Test("replacement with unchanged length and mtime resets file identity")
    func replacement() async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.start()
        try f.append("task_started"); f.emit()
        try await wait { f.values.last?.isWorking == true }
        let url = f.file()
        let old = try Data(contentsOf: url)
        let stamp = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as! Date
        var replacement = Fixture.event("turn_aborted")
        replacement.append(Data(repeating: 32, count: max(0, old.count - replacement.count)))
        #expect(replacement.count == old.count)
        try replacement.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
        f.emit()
        try await wait { f.values.last?.isWorking == false }
    }

    @Test("truncate and delete remove stale active state")
    func truncateAndDelete() async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.start()
        try f.append("task_started"); f.emit()
        try await wait { f.values.last?.isWorking == true }
        try Fixture.event("task_complete").write(to: f.file()); f.emit()
        try await wait { f.values.last?.isWorking == false }
        try f.append("task_started"); f.emit()
        try await wait { f.values.last?.isWorking == true }
        try FileManager.default.removeItem(at: f.file()); f.emit()
        try await wait { f.values.last?.isWorking == false }
    }

    @Test("dropped events reconcile and directory changes discover renamed files")
    func eventLossAndRename() async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.start()
        let renamed = f.root.appendingPathComponent("sessions/renamed.jsonl")
        try FileManager.default.moveItem(at: f.file(), to: renamed)
        try f.sql("UPDATE threads SET rollout_path='renamed.jsonl'")
        let handle = try FileHandle(forWritingTo: renamed)
        try handle.seekToEnd(); try handle.write(contentsOf: Fixture.event("task_started")); try handle.close()
        f.watcher.emit(ActivityFileChanges(reconcile: true))
        try await wait { f.values.last?.isWorking == true }
        #expect(try f.reads().last?["reason"] as? String == "recovery")
    }

    @Test("watcher failure polls, retries, then stops polling after recovery")
    func fallback() async throws {
        var timing = Fixture.timing
        timing.fallback = 0.03; timing.retry = 0.12
        let f = try Fixture(timing: timing, watcherWorks: false)
        defer { f.close() }
        try await f.start()
        try f.append("task_started")
        try await wait { f.values.last?.isWorking == true }
        #expect(try f.reads().contains { $0["reason"] as? String == "fallback" })
        f.watcher.works = true
        try await wait { f.watcher.starts >= 2 }
        try await Task.sleep(for: .milliseconds(90))
        let count = try f.reads().count
        try await Task.sleep(for: .milliseconds(120))
        #expect(try f.reads().count == count)
        try f.append("task_complete"); f.emit()
        try await wait { f.values.last?.isWorking == false }
    }

    @Test("a delivery restart failure enters fallback and recovers")
    func deliveryFailure() async throws {
        var timing = Fixture.timing
        timing.fallback = 0.03; timing.retry = 0.12
        let f = try Fixture(timing: timing)
        defer { f.close() }
        try await f.start()
        f.watcher.works = false
        f.watcher.emit(ActivityFileChanges(reconcile: true, restart: true))
        try f.append("task_started")
        try await wait { f.values.last?.isWorking == true }
        try await wait { (try? f.reads().contains { $0["reason"] as? String == "fallback" }) == true }
        f.watcher.works = true
        try await wait { f.watcher.starts >= 3 }
        try f.append("turn_aborted"); f.emit()
        try await wait { f.values.last?.isWorking == false }
    }

    @Test("continuous writes cannot postpone the fixed coalescing deadline")
    func continuousWrites() async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.start()
        var detectedDuringWrites = false
        for index in 0..<30 {
            try f.append(index == 0 ? "task_started" : "item_completed")
            f.emit()
            try await Task.sleep(for: .milliseconds(10))
            detectedDuringWrites = detectedDuringWrites || f.values.last?.isWorking == true
        }
        #expect(detectedDuringWrites)
        #expect(try f.reads().count < 30)
        try f.append("task_complete"); f.emit()
        try await wait { f.values.last?.isWorking == false }
    }

    @Test("safety reconciliation recovers a missed file event")
    func safety() async throws {
        var timing = Fixture.timing; timing.safety = 0.12
        let f = try Fixture(timing: timing)
        defer { f.close() }
        try await f.start()
        try f.append("task_started")
        try await wait { f.values.last?.isWorking == true }
        #expect(try f.reads().last?["reason"] as? String == "safety")
    }

    @Test("sleep suspends reads and wake reconciles queued changes")
    func sleepWake() async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.start()
        f.observation.environmentChanged(.sleep)
        let count = try f.reads().count
        try f.append("task_started"); f.emit()
        try await Task.sleep(for: .milliseconds(90))
        #expect(try f.reads().count == count)
        f.observation.environmentChanged(.wake)
        try await wait { f.values.last?.isWorking == true }
        #expect(f.watcher.starts == 2)
        #expect(await f.desktop.calls == 2)
    }

    @Test("desktop exit suspends file reads and restart rejects old lifecycle")
    func desktopRestart() async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.start()
        try f.append("task_started"); f.emit()
        try await wait { f.values.last?.isWorking == true }
        await f.desktop.set(nil)
        f.observation.environmentChanged(.desktopChanged)
        try await wait { f.values.last?.isWorking == false }
        let count = try f.reads().count
        f.emit()
        try await Task.sleep(for: .milliseconds(90))
        #expect(try f.reads().count == count)
        await f.desktop.set(Date())
        f.observation.environmentChanged(.desktopChanged)
        try await Task.sleep(for: .milliseconds(90))
        #expect(f.values.last?.isWorking == false)
        try f.append("task_started"); f.emit()
        try await wait { f.values.last?.isWorking == true }
    }

    @Test("freshness expiry publishes without any file read")
    func freshness() async throws {
        let f = try Fixture(launch: Date().addingTimeInterval(-1_000))
        defer { f.close() }
        try Fixture.event("task_started", date: Date().addingTimeInterval(-899)).write(to: f.file())
        try await f.start()
        #expect(f.values.last?.isWorking == true)
        let count = try f.reads().count
        try await wait { f.values.last?.isAvailable == false }
        #expect(try f.reads().count == count)
    }

    @Test("a slightly future log timestamp becomes active without another file event")
    func futureTimestamp() async throws {
        let f = try Fixture()
        defer { f.close() }
        try Fixture.event("task_started", date: Date().addingTimeInterval(0.3)).write(to: f.file())
        try await f.start()
        #expect(f.values.last?.isWorking == false)
        let count = try f.reads().count
        try await wait { f.values.last?.isWorking == true }
        #expect(try f.reads().count == count)
    }

    @Test("database failure is unavailable and recovers on the next database event")
    func databaseFailure() async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.start()
        try f.sql("DROP TABLE threads")
        f.watcher.emit(ActivityFileChanges(catalog: true))
        try await wait { f.values.last?.isAvailable == false }
        let count = try f.reads().count
        try await Task.sleep(for: .milliseconds(150))
        #expect(try f.reads().count == count)
        try f.sql("CREATE TABLE threads (rollout_path TEXT, archived INTEGER, updated_at INTEGER)")
        try f.sql("INSERT INTO threads VALUES ('0.jsonl', 0, 0)")
        try f.append("task_started")
        f.watcher.emit(ActivityFileChanges(catalog: true))
        try await wait { f.values.last?.isWorking == true }
    }

    @Test("a missing WAL recovers without another notification and reads committed WAL changes")
    func databaseRecoversWithoutEvent() async throws {
        let f = try Fixture()
        defer { f.close() }
        try f.sql("PRAGMA journal_mode=WAL")
        let url = f.root.appendingPathComponent("state_1.sqlite")
        let baseline = try Data(contentsOf: url)
        #expect(!FileManager.default.fileExists(atPath: url.path + "-wal"))
        try await f.start()
        #expect(f.values.last?.isAvailable == false)
        #expect(try f.reads(operation: "databaseQuery").last?["errorCategory"] as? String == "walUnavailable")
        #expect(try Data(contentsOf: url) == baseline)
        #expect(!FileManager.default.fileExists(atPath: url.path + "-wal"))
        // An unrelated log event while unavailable must not cancel recovery.
        f.emit()
        try await Task.sleep(for: .milliseconds(100))

        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        let newFile = f.root.appendingPathComponent("sessions/new.jsonl")
        try Fixture.event("task_started").write(to: newFile)
        #expect(sqlite3_exec(database, "UPDATE threads SET archived=1; INSERT INTO threads VALUES ('new.jsonl', 0, 999)", nil, nil, nil) == SQLITE_OK)
        #expect(FileManager.default.fileExists(atPath: url.path + "-wal"))
        // No fake watcher event: the old implementation waited up to 60 seconds.
        try await wait { f.values.last?.isWorking == true }
        #expect(f.values.last?.activeTaskCount == 1)
        #expect(try f.reads().last?["reason"] as? String == "catalogRetry")
        let count = try f.reads().count
        try await Task.sleep(for: .milliseconds(180))
        #expect(try f.reads().count == count)
        #expect(sqlite3_exec(database, "UPDATE threads SET archived=1", nil, nil, nil) == SQLITE_OK)
        f.watcher.emit(ActivityFileChanges(catalog: true))
        try await wait { f.values.last?.isWorking == false }
    }

    @Test("catalog retries back off and are cancelled on sleep and stop")
    func catalogRetryLifetime() async throws {
        var timing = Fixture.timing
        timing.catalogRetry = 0.04
        timing.catalogRetryMaximum = 0.16
        let f = try Fixture(timing: timing)
        defer { f.close() }
        try f.sql("DROP TABLE threads")
        try await f.start()
        try await Task.sleep(for: .milliseconds(300))
        let attempts = try f.reads().count
        #expect(attempts >= 3 && attempts <= 4)
        f.observation.environmentChanged(.sleep)
        try await Task.sleep(for: .milliseconds(220))
        #expect(try f.reads().count == attempts)
        f.observation.environmentChanged(.wake)
        try await wait { (try? f.reads().count) ?? 0 > attempts }
        f.observation.stop()
        let stopped = try f.reads().count
        try await Task.sleep(for: .milliseconds(220))
        #expect(try f.reads().count == stopped)
    }

    @Test("cancellation and replacement subscribers reject old callbacks")
    func cancellation() async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.start()
        let old = f.watcher.handler
        f.consumer?.cancel()
        try await wait { f.watcher.stops >= 2 }
        let count = try f.reads().count
        old?(ActivityFileChanges(reconcile: true))
        try await Task.sleep(for: .milliseconds(80))
        #expect(try f.reads().count == count)
        f.begin()
        try await wait { f.values.count == 2 }
        old?(ActivityFileChanges(reconcile: true))
        try await Task.sleep(for: .milliseconds(80))
        #expect(try f.reads().count == count + 1)
    }

    @Test("events during initial asynchronous discovery are retained")
    func initialRace() async throws {
        let f = try Fixture()
        defer { f.close() }
        await f.desktop.setDelay(.milliseconds(120))
        f.begin()
        try f.append("task_started"); f.emit()
        try await wait { f.values.last?.isWorking == true }
        #expect(f.watcher.starts == 1)
    }

    @Test("stopping during discovery cannot publish into a restarted session")
    func stopDuringDiscovery() async throws {
        let f = try Fixture()
        defer { f.close() }
        await f.desktop.setDelay(.milliseconds(150))
        f.begin()
        try await Task.sleep(for: .milliseconds(30))
        f.observation.stop()
        await f.desktop.setDelay(.zero)
        f.begin()
        try await wait { f.values.count == 1 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(f.values.count == 1)
        #expect(try f.reads().count == 1)
    }

    @Test("cancelling an in-flight parse cannot publish or retain its partial state")
    func stopDuringRead() async throws {
        let f = try Fixture()
        defer { f.close() }
        let record = Fixture.event("task_started")
        var data = Data()
        for _ in 0..<50_000 { data.append(record) }
        try data.write(to: f.file())
        f.begin()
        try await wait { (try? f.reads(phase: "begin").count) == 1 }
        #expect(try f.reads().isEmpty)
        f.observation.stop()
        try Fixture.event("task_complete").write(to: f.file(), options: .atomic)
        f.begin()
        try await wait { f.values.count == 1 }
        #expect(f.values.last?.isWorking == false)
        #expect(f.values.last?.isAvailable == true)
        #expect(try f.reads().contains { $0["outcome"] as? String == "cancelled" })
    }

    @Test("FSEvents filters unrelated files and requests recovery for loss flags")
    func routing() {
        let root = "/tmp/codex"
        #expect(ActivityFileWatcher.classify(path: root + "/logs_1.sqlite-wal", flags: 0, root: root).isEmpty)
        #expect(ActivityFileWatcher.classify(path: root + "/state_1.sqlite-wal", flags: 0, root: root).catalog)
        #expect(ActivityFileWatcher.classify(path: root + "/sqlite/state_2.sqlite", flags: 0, root: root).catalog)
        #expect(ActivityFileWatcher.classify(path: root + "/sessions/a.jsonl", flags: 0, root: root).paths.count == 1)
        #expect(ActivityFileWatcher.classify(path: root + "-other/sessions/a.jsonl", flags: 0, root: root).isEmpty)
        #expect(ActivityFileWatcher.classify(path: root, flags: UInt32(kFSEventStreamEventFlagRootChanged), root: root).restart)
        for flag in [kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagUserDropped, kFSEventStreamEventFlagKernelDropped] {
            #expect(ActivityFileWatcher.classify(path: root, flags: UInt32(flag), root: root).reconcile)
        }
    }

    @Test("native notifications detect a writer that keeps its log open")
    func heldOpenWriter() async throws {
        let f = try Fixture(native: true)
        defer { f.close() }
        let handle = try FileHandle(forWritingTo: f.file())
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Fixture.event("task_complete"))
        try await f.start()
        try handle.write(contentsOf: Fixture.event("task_started"))
        try await wait { f.values.last?.isWorking == true }
        try handle.write(contentsOf: Fixture.event("task_complete"))
        try await wait { f.values.last?.isWorking == false }
    }

    @Test("an open SQLite WAL promptly registers and archives a new held-open log")
    func heldOpenWAL() async throws {
        let f = try Fixture(native: true)
        defer { f.close() }
        var database: OpaquePointer?
        #expect(sqlite3_open(f.root.appendingPathComponent("state_1.sqlite").path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database, "PRAGMA journal_mode=WAL; UPDATE threads SET updated_at=1", nil, nil, nil) == SQLITE_OK)
        try await f.start()
        let newFile = f.root.appendingPathComponent("sessions/new.jsonl")
        try Fixture.event("task_started").write(to: newFile)
        let handle = try FileHandle(forWritingTo: newFile)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try await Task.sleep(for: .milliseconds(180))
        #expect(f.values.last?.isWorking == false)
        #expect(sqlite3_exec(database, "INSERT INTO threads VALUES ('new.jsonl', 0, 2)", nil, nil, nil) == SQLITE_OK)
        try await wait { f.values.last?.isWorking == true }
        #expect(sqlite3_exec(database, "UPDATE threads SET archived=1 WHERE rollout_path='new.jsonl'", nil, nil, nil) == SQLITE_OK)
        try await wait { f.values.last?.isWorking == false }
    }

    @Test("a deleted log recreated with an open writer is watched again")
    func nativeRecreation() async throws {
        let f = try Fixture(native: true)
        defer { f.close() }
        try await f.start()
        try f.append("task_started")
        try await wait { f.values.last?.isWorking == true }
        try FileManager.default.removeItem(at: f.file())
        try await wait { f.values.last?.isWorking == false }
        let descriptor = open(f.file().path, O_WRONLY | O_CREAT, 0o600)
        #expect(descriptor >= 0)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: Fixture.event("task_started"))
        try await wait { f.values.last?.isWorking == true }
    }

    @Test("real native watcher discovers a missing root and receives file appends")
    func nativeEvents() async throws {
        let f = try Fixture(native: true)
        defer { f.close() }
        let displaced = f.root.appendingPathExtension("saved")
        try FileManager.default.moveItem(at: f.root, to: displaced)
        defer { try? FileManager.default.removeItem(at: displaced) }
        try await f.start()
        #expect(f.values.last?.isAvailable == false)
        try FileManager.default.moveItem(at: displaced, to: f.root)
        try await wait { f.values.last?.isAvailable == true }
        try f.append("task_started")
        try await wait { f.values.last?.isWorking == true }
        try f.append("task_complete")
        try await wait { f.values.last?.isWorking == false }
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
        if !condition() { throw FixtureError.timeout }
    }
}

private enum FixtureError: Error { case timeout, database }

private actor Desktop {
    var launch: Date?
    var calls = 0
    var delay = Duration.zero
    init(_ launch: Date?) { self.launch = launch }
    func read() async -> Date? {
        calls += 1
        let result = launch
        try? await Task.sleep(for: delay)
        return result
    }
    func set(_ launch: Date?) { self.launch = launch }
    func setDelay(_ delay: Duration) { self.delay = delay }
}

@MainActor
private final class FakeWatcher: ActivityWatching {
    var works = true
    var starts = 0
    var stops = 0
    var handler: (@Sendable (ActivityFileChanges) -> Void)?
    func start(_ receive: @escaping @Sendable (ActivityFileChanges) -> Void) -> Bool {
        starts += 1; handler = receive; return works
    }
    func stop() { stops += 1; handler = nil }
    func emit(_ value: ActivityFileChanges) { handler?(value) }
}

@MainActor
private final class Fixture {
    static var timing: ActivityObservationTiming {
        ActivityObservationTiming(batch: 0.02, catalog: 0.05, safety: 60, fallback: 2, retry: 30, tolerance: 0)
    }
    let root: URL
    let logs: URL
    let recorder: DiagnosticRecorder
    let desktop: Desktop
    let watcher: FakeWatcher
    let observation: CodexActivityObservation
    var consumer: Task<Void, Never>?
    var values: [CodexActivitySnapshot] = []

    init(count: Int = 1, timing: ActivityObservationTiming = Fixture.timing, watcherWorks: Bool = true,
         launch: Date = Date().addingTimeInterval(-2), native: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("activity-events-\(UUID())")
            .resolvingSymlinksInPath()
        logs = root.appendingPathExtension("diagnostics")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        recorder = DiagnosticRecorder(directory: logs, enabled: true)
        desktop = Desktop(launch)
        watcher = FakeWatcher(); watcher.works = watcherWorks
        let desktop = desktop
        let reader = CodexActivityReader(diagnostics: recorder, codexHome: root, desktopLaunchDateProvider: { await desktop.read() })
        observation = CodexActivityObservation(reader: reader, diagnostics: recorder,
            watcher: native ? ActivityFileWatcher(root: root) : watcher, timing: timing, observeSystem: false)
        try sql("CREATE TABLE threads (rollout_path TEXT, archived INTEGER, updated_at INTEGER)")
        for index in 0..<count {
            try Self.event("task_complete").write(to: file(index))
            try sql("INSERT INTO threads VALUES ('\(index).jsonl', 0, \(index))")
        }
    }

    func begin() {
        consumer?.cancel()
        let stream = observation.snapshots()
        consumer = Task { [weak self] in
            for await value in stream { self?.values.append(value) }
        }
    }

    func start() async throws {
        begin()
        let deadline = ContinuousClock.now + .seconds(2)
        while values.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        if values.isEmpty { throw FixtureError.timeout }
    }

    func file(_ index: Int = 0) -> URL { root.appendingPathComponent("sessions/\(index).jsonl") }
    func append(_ type: String, index: Int = 0) throws { try appendData(Self.event(type), index: index) }
    func appendData(_ data: Data, index: Int = 0) throws {
        let handle = try FileHandle(forWritingTo: file(index))
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }
    func emit(index: Int = 0) { watcher.emit(ActivityFileChanges(paths: [file(index).path])) }
    func sql(_ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("state_1.sqlite").path, &db) == SQLITE_OK else { throw FixtureError.database }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw FixtureError.database }
    }
    func reads(phase: String = "end", operation: String = "activityRead") throws -> [[String: Any]] {
        recorder.flush()
        let files = try FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)
        return try files.filter { $0.pathExtension == "jsonl" }.flatMap { url in
            try Data(contentsOf: url).split(separator: 10).compactMap { line -> [String: Any]? in
                guard let record = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let fields = record["fields"] as? [String: Any], fields["operation"] as? String == operation,
                      fields["phase"] as? String == phase else { return nil }
                return fields
            }
        }
    }
    func close() {
        consumer?.cancel(); observation.stop(); recorder.shutdown()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: logs)
    }
    static func event(_ type: String, date: Date = Date()) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return Data("{\"type\":\"event_msg\",\"timestamp\":\"\(formatter.string(from: date))\",\"payload\":{\"type\":\"\(type)\"}}\n".utf8)
    }
}
