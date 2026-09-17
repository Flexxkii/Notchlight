import Foundation
import Darwin
import os

struct DiagnosticConfiguration: Sendable {
    var maximumPendingBytes = 1_048_576
    var maximumFileBytes = 10 * 1_048_576
    var maximumTotalBytes = 50 * 1_048_576
    var maximumAge: TimeInterval = 24 * 60 * 60
    var rotationAge: TimeInterval = 60 * 60
}

/// Producers only enqueue bounded, typed metadata. Sampling, encoding and disk
/// operations are serialized on one utility queue; no task is created per event.
public final class DiagnosticRecorder: @unchecked Sendable {
    public static let disabled = DiagnosticRecorder(permanentNoOp: true)
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.notchlight.diagnostics", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let directory: URL
    private let permanentNoOp: Bool
    private let config: DiagnosticConfiguration
    private let sampler: @Sendable () throws -> ProcessResourceSnapshot
    private let wallClock: @Sendable () -> Date
    private let monotonicClock: @Sendable () -> UInt64
    private let samplingInterval: DispatchTimeInterval
    private let signposter = OSSignposter(subsystem: "com.teodor.Notchlight", category: "Performance")

    // Protected by lock. Producers never hold it while doing I/O or callbacks.
    private var enabled = false
    private var stopped = false
    private var errorCategory: String?
    private var statusCallback: (@Sendable (DiagnosticStatus) -> Void)?
    private var session = UUID().uuidString
    private var sequence: UInt64 = 0
    private var intervalSequence: UInt64 = 0
    private var activeIntervals = Set<UInt64>()
    private var context: [String: DiagnosticValue] = [:]
    private var revision: UInt64 = 0
    private var pending: [DiagnosticRecord] = []
    private var pendingBytes = 0
    private var dropped = 0
    private var drainScheduled = false
    private var resetScheduled = false
    private var pendingResetReason: String?
    private var counters: [DiagnosticCounter: (count: Int, duration: UInt64)] = [:]

    // Queue-confined state.
    private var sampleTimer: DispatchSourceTimer?
    private var flushTimer: DispatchSourceTimer?
    private var previous: SampleBaseline?
    private var counterStart: UInt64 = 0
    private var file: FileHandle?
    private var fileURL: URL?
    private var fileBytes = 0
    private var fileIndex = 0
    private var fileOpened = Date.distantPast
    private var writerFailed = false

    public var isEnabled: Bool { lock.withLock { enabled } }
    public var status: DiagnosticStatus {
        lock.withLock { DiagnosticStatus(isEnabled: enabled, errorCategory: errorCategory, directory: directory) }
    }
    public var onStatusChange: (@Sendable (DiagnosticStatus) -> Void)? {
        get { lock.withLock { statusCallback } }
        set { lock.withLock { statusCallback = newValue } }
    }

    public convenience init(directory: URL? = nil, enabled: Bool = true) {
        self.init(directory: directory, enabled: enabled, permanentNoOp: false,
                  sampler: { try ProcessResourceSnapshot.read() }, wallClock: { Date() },
                  monotonicClock: { DispatchTime.now().uptimeNanoseconds }, samplingInterval: .seconds(2))
    }

    private convenience init(permanentNoOp: Bool) {
        self.init(directory: nil, enabled: false, permanentNoOp: permanentNoOp,
                  sampler: { try ProcessResourceSnapshot.read() }, wallClock: { Date() },
                  monotonicClock: { DispatchTime.now().uptimeNanoseconds }, samplingInterval: .seconds(2))
    }

    private init(directory: URL?, enabled: Bool, permanentNoOp: Bool,
                 sampler: @escaping @Sendable () throws -> ProcessResourceSnapshot,
                 wallClock: @escaping @Sendable () -> Date,
                 monotonicClock: @escaping @Sendable () -> UInt64,
                 samplingInterval: DispatchTimeInterval, configuration: DiagnosticConfiguration = .init()) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Notchlight/Diagnostics", isDirectory: true)
        self.permanentNoOp = permanentNoOp
        self.sampler = sampler
        self.wallClock = wallClock
        self.monotonicClock = monotonicClock
        self.samplingInterval = samplingInterval
        config = configuration
        queue.setSpecific(key: queueKey, value: true)
        if enabled { setEnabled(true) }
    }

    internal convenience init(testDirectory: URL, sampler: @escaping @Sendable () throws -> ProcessResourceSnapshot,
                              wallClock: @escaping @Sendable () -> Date,
                              monotonicClock: @escaping @Sendable () -> UInt64,
                              samplingInterval: DispatchTimeInterval = .seconds(3_600),
                              configuration: DiagnosticConfiguration = .init()) {
        self.init(directory: testDirectory, enabled: true, permanentNoOp: false, sampler: sampler,
                  wallClock: wallClock, monotonicClock: monotonicClock, samplingInterval: samplingInterval,
                  configuration: configuration)
    }
    internal func sampleNowForTesting() { onQueue { sample() } }
    internal var pendingByteCountForTesting: Int { lock.withLock { pendingBytes } }
    internal func blockWriterForTesting(_ body: @escaping @Sendable () -> Void) { queue.async(execute: body) }

    deinit { shutdown() }

    public func setEnabled(_ value: Bool) {
        guard !permanentNoOp else { return }
        onQueue {
            let change = lock.withLock { () -> Bool in
                guard !stopped, enabled != value else { return false }
                enabled = value
                errorCategory = nil
                activeIntervals.removeAll()
                if value { session = UUID().uuidString; sequence = 0 }
                return true
            }
            guard change else { return }
            previous = nil
            if value {
                writerFailed = false
                fileIndex = 0
                counterStart = monotonicClock()
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                          attributes: [.posixPermissions: 0o700])
                    try prune()
                    var fields = DiagnosticEnvironment.fields()
                    fields["phase"] = .string("sessionStart")
                    append(.lifecycle, fields: fields)
                    let cached = lock.withLock { context }
                    if !cached.isEmpty { append(.context, fields: cached) }
                    sample()
                    drain()
                    startTimers()
                } catch { failWriter("directoryUnavailable") }
            } else {
                stopTimers()
                emitCounters(force: true)
                append(.lifecycle, fields: ["phase": .string("disabled")], force: true)
                drain()
                do { try closeFile() } catch { failWriter("writeFailed") }
            }
            notifyStatus()
        }
    }

    public func record(_ event: DiagnosticEventName, fields: [String: DiagnosticValue] = [:]) {
        guard !permanentNoOp else { return }
        append(event, fields: fields)
    }

    public func updateContext(_ fields: [String: DiagnosticValue]) {
        guard !permanentNoOp else { return }
        let allowed = Self.filtered(fields)
        let schedule = lock.withLock { () -> Bool in
            var changed: [String: DiagnosticValue] = [:]
            for (key, value) in allowed where context[key] != value { context[key] = value; changed[key] = value }
            guard !changed.isEmpty else { return false }
            revision &+= 1
            guard enabled, !stopped else { return false }
            changed["contextRevision"] = .int(Int64(clamping: revision))
            return appendLocked(.context, fields: changed)
        }
        scheduleDrain(if: schedule)
    }

    public func beginInterval(_ operation: DiagnosticOperation) -> DiagnosticInterval {
        let active = !permanentNoOp && isEnabled
        let start = active ? monotonicClock() : 0
        let id = lock.withLock { () -> UInt64 in
            guard active, enabled, !stopped else { return 0 }
            intervalSequence &+= 1
            activeIntervals.insert(intervalSequence)
            return intervalSequence
        }
        let state = id == 0 ? nil : signposter.beginInterval("Operation", id: signposter.makeSignpostID(), "\(operation.rawValue, privacy: .public)")
        if id != 0 { append(.operation, fields: ["phase": .string("begin"), "operation": .string(operation.rawValue), "intervalID": .int(Int64(clamping: id))]) }
        return DiagnosticInterval(id: id, operation: operation, signpostState: state,
                                  startMonotonicNanoseconds: start, startWallNanoseconds: 0)
    }

    public func endInterval(_ interval: DiagnosticInterval, outcome: DiagnosticOutcome = .success,
                            fields: [String: DiagnosticValue] = [:]) {
        guard interval.id != 0 else { return }
        if let state = interval.signpostState { signposter.endInterval("Operation", state) }
        let active = lock.withLock { activeIntervals.remove(interval.id) != nil && enabled && !stopped }
        guard active else { return }
        let end = monotonicClock()
        var output = fields
        output["operation"] = .string(interval.operation.rawValue)
        output["phase"] = .string("end")
        output["intervalID"] = .int(Int64(clamping: interval.id))
        output["outcome"] = .string(outcome.rawValue)
        output["durationNanoseconds"] = .int(Int64(clamping: end >= interval.startMonotonicNanoseconds ? end - interval.startMonotonicNanoseconds : 0))
        append(.operation, fields: output)
    }

    public func aggregate(_ counter: DiagnosticCounter, durationNanoseconds: UInt64 = 0, count: Int = 1) {
        guard !permanentNoOp, count > 0 else { return }
        lock.withLock {
            guard enabled, !stopped else { return }
            let old = counters[counter] ?? (0, 0)
            counters[counter] = (old.count &+ count, old.duration &+ durationNanoseconds)
        }
    }

    public func resetBaseline(reason: String) {
        guard !permanentNoOp else { return }
        let schedule = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            pendingResetReason = String(reason.prefix(80))
            guard !resetScheduled else { return false }
            resetScheduled = true
            return true
        }
        guard schedule else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let reason = self.lock.withLock {
                let reason = self.pendingResetReason ?? "unspecified"
                self.pendingResetReason = nil
                self.resetScheduled = false
                return reason
            }
            self.previous = nil
            self.append(.lifecycle, fields: ["phase": .string("baselineReset"), "reason": .string(reason)])
        }
    }

    public func flush() {
        guard !permanentNoOp else { return }
        onQueue {
            drain()
            do { try file?.synchronize() } catch { failWriter("writeFailed") }
        }
    }

    public func shutdown() {
        guard !permanentNoOp else { return }
        onQueue {
            let wasEnabled = lock.withLock { () -> Bool in
                guard !stopped else { return false }
                stopped = true
                let was = enabled
                enabled = false
                activeIntervals.removeAll()
                return was
            }
            stopTimers()
            if wasEnabled {
                emitCounters(force: true)
                append(.lifecycle, fields: ["phase": .string("shutdown")], force: true)
            }
            drain()
            do { try closeFile() } catch { failWriter("writeFailed") }
        }
    }

    public func export(to url: URL) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("NotchlightDiagnostics-\(UUID().uuidString)")
        let logs = root.appendingPathComponent("logs")
        try fm.createDirectory(at: logs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let copies: [URL] = try onQueue {
            drain()
            try file?.synchronize()
            try prune()
            guard fm.fileExists(atPath: directory.path) else { return [] }
            let sources = try logFiles()
            return try sources.map { source in
                let destination = logs.appendingPathComponent(source.lastPathComponent)
                try fm.copyItem(at: source, to: destination)
                return destination
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metadata = ExportMetadata(schemaVersion: 1, exportedAt: wallClock().ISO8601Format(),
                                      environment: DiagnosticEnvironment.fields(), logFiles: copies.map(\.lastPathComponent))
        try encoder.encode(metadata).write(to: root.appendingPathComponent("metadata.json"), options: .atomic)
        try DiagnosticReport.render(logURLs: copies).write(to: root.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        // Build beside the requested destination, then replace only after ditto succeeds.
        let temporaryZip = url.deletingLastPathComponent().appendingPathComponent(".Notchlight-\(UUID().uuidString).zip")
        defer { try? fm.removeItem(at: temporaryZip) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl", "--keepParent", root.path, temporaryZip.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: temporaryZip) }
        else { try fm.moveItem(at: temporaryZip, to: url) }
    }

    private func sample() {
        guard isEnabled else { return }
        let tick = monotonicClock(), date = wallClock()
        let state = lock.withLock { (context, revision) }
        do {
            let snapshot = try sampler()
            var fields = state.0
            fields.merge([
                "processStartIdentity": .int(Int64(clamping: snapshot.processStartIdentity)),
                "userTimeNanoseconds": .int(Int64(clamping: snapshot.userTimeNanoseconds)),
                "systemTimeNanoseconds": .int(Int64(clamping: snapshot.systemTimeNanoseconds)),
                "physicalFootprintBytes": .int(Int64(clamping: snapshot.physicalFootprintBytes)),
                "residentBytes": .int(Int64(clamping: snapshot.residentBytes)),
                "diskReadBytes": .int(Int64(clamping: snapshot.diskReadBytes)),
                "diskWriteBytes": .int(Int64(clamping: snapshot.diskWriteBytes)),
                "pageins": .int(Int64(clamping: snapshot.pageins)),
                "packageIdleWakeups": .int(Int64(clamping: snapshot.packageIdleWakeups)),
                "interruptWakeups": .int(Int64(clamping: snapshot.interruptWakeups)),
                "contextRevision": .int(Int64(clamping: state.1)),
                "thermal": .string(Self.thermalName),
                "lowPower": .bool(ProcessInfo.processInfo.isLowPowerModeEnabled)
            ]) { _, new in new }
            var reason = "initial"
            if let prior = previous {
                let a = prior.snapshot
                let monotonic = tick > prior.tick
                let elapsed = monotonic ? tick - prior.tick : 0
                let clockGap = abs(date.timeIntervalSince(prior.date) - Double(elapsed) / 1e9) > 5
                let countersValid = snapshot.processStartIdentity == a.processStartIdentity &&
                    snapshot.userTimeNanoseconds >= a.userTimeNanoseconds && snapshot.systemTimeNanoseconds >= a.systemTimeNanoseconds &&
                    snapshot.diskReadBytes >= a.diskReadBytes && snapshot.diskWriteBytes >= a.diskWriteBytes &&
                    snapshot.pageins >= a.pageins && snapshot.packageIdleWakeups >= a.packageIdleWakeups && snapshot.interruptWakeups >= a.interruptWakeups
                if monotonic, countersValid, !clockGap {
                    let cpu = (snapshot.userTimeNanoseconds - a.userTimeNanoseconds) + (snapshot.systemTimeNanoseconds - a.systemTimeNanoseconds)
                    fields["cpuDeltaNanoseconds"] = .int(Int64(clamping: cpu))
                    fields["elapsedNanoseconds"] = .int(Int64(clamping: elapsed))
                    fields["cpuPercent"] = .double(100 * Double(cpu) / Double(elapsed))
                    fields["diskReadDeltaBytes"] = .int(Int64(clamping: snapshot.diskReadBytes - a.diskReadBytes))
                    fields["diskWriteDeltaBytes"] = .int(Int64(clamping: snapshot.diskWriteBytes - a.diskWriteBytes))
                    fields["packageIdleWakeupDelta"] = .int(Int64(clamping: snapshot.packageIdleWakeups - a.packageIdleWakeups))
                    fields["interruptWakeupDelta"] = .int(Int64(clamping: snapshot.interruptWakeups - a.interruptWakeups))
                    fields["pageinDelta"] = .int(Int64(clamping: snapshot.pageins - a.pageins))
                    fields["mixedState"] = .bool(state.1 != prior.revision)
                    fields["sampleGap"] = .bool(elapsed > 4_500_000_000)
                    reason = ""
                } else { reason = clockGap ? "clockDiscontinuity" : "counterDiscontinuity" }
            }
            if !reason.isEmpty { fields["baseline"] = .string(reason) }
            append(.resourceSample, fields: fields, tick: tick, date: date)
            previous = SampleBaseline(snapshot: snapshot, tick: tick, date: date, revision: state.1)
            if lock.withLock({ errorCategory == "samplingFailed" }) { setError(nil) }
        } catch {
            previous = nil
            append(.resourceSample, fields: ["sampleAvailable": .bool(false), "errorCategory": .string("samplingFailed")], tick: tick, date: date)
            setError("samplingFailed")
        }
        emitCounters(force: false)
    }

    private func emitCounters(force: Bool) {
        let tick = monotonicClock()
        guard force || (tick >= counterStart && tick - counterStart >= 10_000_000_000) else { return }
        let values = lock.withLock { let copy = counters; counters.removeAll(keepingCapacity: true); return copy }
        var fields: [String: DiagnosticValue] = ["elapsedNanoseconds": .int(Int64(clamping: tick >= counterStart ? tick - counterStart : 0)), "partial": .bool(force)]
        for (key, value) in values {
            fields["\(key.rawValue).count"] = .int(Int64(value.count))
            fields["\(key.rawValue).durationNanoseconds"] = .int(Int64(clamping: value.duration))
        }
        if !values.isEmpty { append(.counters, fields: fields, force: force) }
        counterStart = tick
    }

    private func startTimers() {
        sampleTimer = DispatchSource.makeTimerSource(queue: queue)
        sampleTimer?.schedule(deadline: .now() + samplingInterval, repeating: samplingInterval, leeway: .milliseconds(200))
        sampleTimer?.setEventHandler { [weak self] in self?.sample() }
        sampleTimer?.resume()
        flushTimer = DispatchSource.makeTimerSource(queue: queue)
        flushTimer?.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5), leeway: .milliseconds(200))
        flushTimer?.setEventHandler { [weak self] in self?.drain() }
        flushTimer?.resume()
    }
    private func stopTimers() {
        sampleTimer?.cancel(); sampleTimer = nil
        flushTimer?.cancel(); flushTimer = nil
    }

    private func append(_ event: DiagnosticEventName, fields: [String: DiagnosticValue], force: Bool = false,
                        tick: UInt64? = nil, date: Date? = nil) {
        let allowed = Self.filtered(fields)
        let schedule = lock.withLock { () -> Bool in
            guard force || (enabled && !stopped) else { return false }
            return appendLocked(event, fields: allowed, tick: tick, date: date)
        }
        scheduleDrain(if: schedule)
    }
    private func appendLocked(_ event: DiagnosticEventName, fields: [String: DiagnosticValue], tick: UInt64? = nil, date: Date? = nil) -> Bool {
        sequence &+= 1
        // Conservative allocation/escaped-JSON bound. No unbounded async closures.
        let size = fields.reduce(1_024) { sum, pair in sum + pair.key.utf8.count * 6 + pair.value.estimatedBytes + 128 }
        guard size <= config.maximumPendingBytes, pendingBytes <= config.maximumPendingBytes - size else { dropped += 1; return false }
        pending.append(DiagnosticRecord(schemaVersion: 1, sessionUUID: session, sequence: sequence,
                                       wallTime: date ?? wallClock(), monotonicNanoseconds: tick ?? monotonicClock(), event: event, fields: fields))
        pendingBytes += size
        if pendingBytes >= 65_536, !drainScheduled { drainScheduled = true; return true }
        return false
    }
    private func scheduleDrain(if needed: Bool) {
        if needed { queue.async { [weak self] in self?.drain() } }
    }

    private func drain() {
        let batch = lock.withLock { () -> [DiagnosticRecord] in
            var batch = pending
            pending.removeAll(keepingCapacity: true)
            pendingBytes = 0
            drainScheduled = false
            if dropped > 0 {
                sequence &+= 1
                batch.append(DiagnosticRecord(schemaVersion: 1, sessionUUID: session, sequence: sequence, wallTime: wallClock(),
                    monotonicNanoseconds: monotonicClock(), event: .failure,
                    fields: ["errorCategory": .string("eventsDropped"), "droppedCount": .int(Int64(dropped))]))
                dropped = 0
            }
            return batch
        }
        guard !writerFailed, !batch.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = Data()
        do {
            for record in batch {
                let encoded = try encoder.encode(record) + Data([10])
                if !data.isEmpty, data.count + encoded.count > min(65_536, config.maximumFileBytes) {
                    try write(data); data.removeAll(keepingCapacity: true)
                }
                data.append(encoded)
            }
            if !data.isEmpty { try write(data) }
            try file?.synchronize()
            try prune()
        } catch { failWriter("writeFailed") }
    }

    private func write(_ data: Data) throws {
        guard data.count <= config.maximumFileBytes else { throw CocoaError(.fileWriteUnknown) }
        if file != nil, fileBytes + data.count > config.maximumFileBytes || wallClock().timeIntervalSince(fileOpened) >= min(config.rotationAge, config.maximumAge) {
            try closeFile()
        }
        if file == nil {
            let name = lock.withLock { session }
            let url = directory.appendingPathComponent("session-\(name)-\(String(format: "%05d", fileIndex)).jsonl")
            fileIndex += 1
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            file = try FileHandle(forWritingTo: url)
            fileURL = url
            fileBytes = 0
            fileOpened = wallClock()
            try FileManager.default.setAttributes([.creationDate: fileOpened], ofItemAtPath: url.path)
        }
        try file?.write(contentsOf: data)
        fileBytes += data.count
    }
    private func closeFile() throws {
        var failure: Error?
        if let handle = file {
            do { try handle.synchronize() } catch { failure = error }
            do { try handle.close() } catch { if failure == nil { failure = error } }
        }
        file = nil; fileURL = nil; fileBytes = 0
        if let failure { throw failure }
    }
    private func logFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .creationDateKey])
            .filter { url in
                guard url.lastPathComponent.hasPrefix("session-"), url.pathExtension == "jsonl", let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
                return values.isRegularFile == true && values.isSymbolicLink != true
            }
    }
    private func prune() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let files = try logFiles().map { url in (url, try url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])) }
            .sorted { ($0.1.creationDate ?? .distantPast) < ($1.1.creationDate ?? .distantPast) }
        var bytes = files.reduce(0) { $0 + ($1.1.fileSize ?? 0) }
        let cutoff = wallClock().addingTimeInterval(-config.maximumAge)
        for (url, values) in files where url != fileURL {
            if (values.creationDate ?? .distantPast) <= cutoff || bytes > config.maximumTotalBytes {
                try FileManager.default.removeItem(at: url)
                bytes -= values.fileSize ?? 0
            }
        }
    }
    private func failWriter(_ category: String) {
        writerFailed = true
        stopTimers()
        lock.withLock {
            enabled = false
            pending.removeAll()
            pendingBytes = 0
            dropped = 0
            counters.removeAll(keepingCapacity: true)
            activeIntervals.removeAll()
        }
        try? closeFile()
        setError(category)
    }
    private func setError(_ category: String?) {
        let changed = lock.withLock { let changed = errorCategory != category; errorCategory = category; return changed }
        if changed { notifyStatus() }
    }
    private func notifyStatus() { let callback = onStatusChange; callback?(status) }
    private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return try body() }
        return try queue.sync(execute: body)
    }

    private static func filtered(_ fields: [String: DiagnosticValue]) -> [String: DiagnosticValue] {
        fields.filter { key, value in
            let displayParts = key.split(separator: ".")
            let displayKey = displayParts.count == 3 && displayParts[0] == "display" && Int(displayParts[1]) != nil && ["width", "height", "scale"].contains(String(displayParts[2]))
            guard allowedKeys.contains(key) || displayKey else { return false }
            if case .double(let number) = value { return number.isFinite }
            if case .string(let text) = value { return text.utf8.count <= 256 && !text.contains("\n") && !text.contains("/") && !text.contains("\\") && !text.contains("@") }
            return true
        }
    }
    private static let allowedKeys: Set<String> = [
        "activity_watcher", "recoveryCount", "watcherFailures", "reconcileCount", "active_task_count", "border_effective_enabled", "border_enabled", "border_spacing_points", "bytesRead", "cachedFiles", "category", "changedFiles", "codex_activity_available", "codex_connected", "codex_monitoring", "codex_working", "diskReadBytes", "diskWriteBytes", "display.count", "enabled", "glow_enabled", "inactivity_timeout_minutes", "interruptWakeups", "launchID", "line_width_points", "menu", "notch.count", "operation", "outcome", "packageIdleWakeups", "pageins", "panel.visible", "parseFailures", "parsedRecords", "partial", "phase", "physicalFootprintBytes", "pid", "preview_present", "preview_pulse_active", "pulse", "pulse.animationActive", "pulse_requested", "reduceMotion", "render.lastUpdateAnimated", "residentBytes", "rolloutPaths", "rpcBytesReceived", "sampleAvailable", "show_only_while_working", "startIdentity", "started", "strips_enabled", "swipe.enabled", "swipe.eventPhase", "swipe.phase", "swipe.status", "swipe.transitionPhase", "systemTimeNanoseconds", "unreadableFiles", "usage_available", "usage_refreshing", "usage_stale", "userTimeNanoseconds",
        "settings_visible", "settings_minimized", "settings_occluded", "system_sleeping", "diagnostics_exporting", "hovered", "visible", "hiddenReason", "metadataChecks", "databaseAvailable", "queryRows",
        "processStartIdentity", "cpuDeltaNanoseconds", "elapsedNanoseconds", "cpuPercent", "diskReadDeltaBytes", "diskWriteDeltaBytes", "packageIdleWakeupDelta", "interruptWakeupDelta", "pageinDelta", "contextRevision", "mixedState", "sampleGap", "baseline", "reason", "errorCategory", "droppedCount", "intervalID", "durationNanoseconds", "mouse.count", "mouse.durationNanoseconds", "overlayUpdate.count", "overlayUpdate.durationNanoseconds", "render.count", "render.durationNanoseconds",
        "version", "build", "configuration", "buildConfiguration", "executableUUID", "machUUID", "os", "logicalCPUCount", "physicalMemoryBytes", "thermal", "lowPower"
    ]
    private static var thermalName: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

private struct SampleBaseline {
    let snapshot: ProcessResourceSnapshot
    let tick: UInt64
    let date: Date
    let revision: UInt64
}
private struct DiagnosticRecord: Encodable {
    let schemaVersion: Int
    let sessionUUID: String
    let sequence: UInt64
    let wallTime: Date
    let monotonicNanoseconds: UInt64
    let event: DiagnosticEventName
    let fields: [String: DiagnosticValue]
}
private struct ExportMetadata: Encodable {
    let schemaVersion: Int
    let exportedAt: String
    let environment: [String: DiagnosticValue]
    let logFiles: [String]
}
private extension DiagnosticValue {
    var estimatedBytes: Int {
        if case .string(let value) = self { return value.utf8.count * 6 + 64 }
        return 64
    }
}
