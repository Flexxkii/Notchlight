import AppKit
import Diagnostics

struct ActivityObservationTiming: Sendable {
    var batch: TimeInterval = 0.25
    var catalog: TimeInterval = 1
    var safety: TimeInterval = 60
    var fallback: TimeInterval = 2
    var retry: TimeInterval = 30
    var tolerance: TimeInterval = 5
    var catalogRetry: TimeInterval = 1
    var catalogRetryMaximum: TimeInterval = 30
}

enum ActivityEnvironmentEvent { case desktopChanged, sleep, wake }

/// A single, cancellable activity subscription. AppKit/FSEvents ownership stays on
/// the main actor; disk reads and parsing remain on CodexActivityReader's actor.
@MainActor
public final class CodexActivityObservation {
    private let reader: CodexActivityReader
    private let diagnostics: DiagnosticRecorder
    private let watcher: any ActivityWatching
    private let timing: ActivityObservationTiming
    private let observeSystem: Bool
    private var observers: [NSObjectProtocol] = []
    private var continuation: AsyncStream<CodexActivitySnapshot>.Continuation?
    private var lastSnapshot: CodexActivitySnapshot?
    private var generation = 0
    private var environmentRevision = 0
    private var watcherRevision = 0
    private var launchDate: Date?
    private var sleeping = false
    private var ready = false
    private var watching = false
    private var watcherFailures: Int64 = 0
    private var recoveries: Int64 = 0
    private var reconciliations: Int64 = 0
    private var pending = ActivityFileChanges()
    private var lastCatalog = Date.distantPast
    private var nextRetry = Date.distantPast
    private var environmentTask: Task<Void, Never>?
    private var readTask: Task<Void, Never>?
    private var batchTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var catalogRetryTask: Task<Void, Never>?
    private var catalogRetryDelay: TimeInterval = 0

    public convenience init(diagnostics: DiagnosticRecorder = .disabled, codexHome: URL? = nil) {
        let reader = CodexActivityReader(diagnostics: diagnostics, codexHome: codexHome)
        self.init(reader: reader, diagnostics: diagnostics,
                  watcher: ActivityFileWatcher(root: reader.codexHome))
    }

    init(reader: CodexActivityReader, diagnostics: DiagnosticRecorder = .disabled,
         watcher: any ActivityWatching, timing: ActivityObservationTiming = .init(), observeSystem: Bool = true) {
        self.reader = reader
        self.diagnostics = diagnostics
        self.watcher = watcher
        self.timing = timing
        self.observeSystem = observeSystem
    }

    /// Replaces any previous subscriber. Cancelling the consumer also stops observation.
    public func snapshots() -> AsyncStream<CodexActivitySnapshot> {
        stop()
        let current = generation
        let pair = AsyncStream<CodexActivitySnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == current else { return }
                self.stop()
            }
        }
        installObservers()
        // Establish the stream before discovery or the initial read. Incoming
        // changes remain pending while the reader is reconciling its baseline.
        startWatcher()
        refreshEnvironment()
        return pair.stream
    }

    public func stop() {
        generation &+= 1
        environmentRevision &+= 1
        watcherRevision &+= 1
        continuation?.finish()
        continuation = nil
        cancelWork()
        watcher.stop()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        pending = ActivityFileChanges()
        lastSnapshot = nil
        launchDate = nil
        lastCatalog = .distantPast
        sleeping = false
        ready = false
        watching = false
        watcherFailures = 0
        recoveries = 0
        reconciliations = 0
        diagnostics.updateContext(["activity_watcher": .string("stopped")])
    }

    isolated deinit { stop() }

    private func cancelWork() {
        environmentTask?.cancel(); environmentTask = nil
        readTask?.cancel(); readTask = nil
        batchTask?.cancel(); batchTask = nil
        expiryTask?.cancel(); expiryTask = nil
        maintenanceTask?.cancel(); maintenanceTask = nil
        catalogRetryTask?.cancel(); catalogRetryTask = nil
        catalogRetryDelay = 0
    }

    private func installObservers() {
        guard observeSystem else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let id = application.bundleIdentifier,
                      id == "com.openai.codex" || id == "com.openai.chatgpt" else { return }
                MainActor.assumeIsolated { self?.environmentChanged(.desktopChanged) }
            })
        }
        for (name, event) in [(NSWorkspace.willSleepNotification, ActivityEnvironmentEvent.sleep),
                              (NSWorkspace.didWakeNotification, .wake)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.environmentChanged(event) }
            })
        }
    }

    func environmentChanged(_ event: ActivityEnvironmentEvent) {
        guard continuation != nil else { return }
        environmentRevision &+= 1
        cancelWork()
        ready = false
        pending = ActivityFileChanges(reconcile: true)
        switch event {
        case .sleep:
            sleeping = true
            watcherRevision &+= 1
            watcher.stop()
            watching = false
            diagnostics.updateContext(["activity_watcher": .string("sleeping")])
        case .wake:
            sleeping = false
            startWatcher()
            refreshEnvironment()
        case .desktopChanged:
            if !sleeping { refreshEnvironment() }
        }
    }

    private func refreshEnvironment() {
        environmentTask?.cancel()
        environmentRevision &+= 1
        let revision = environmentRevision, current = generation
        let reader = reader
        environmentTask = Task { [weak self] in
            let launch = await reader.currentDesktopLaunchDate()
            guard !Task.isCancelled, let self, self.generation == current,
                  self.environmentRevision == revision, !self.sleeping else { return }
            self.environmentTask = nil
            self.launchDate = launch
            self.ready = true
            self.pending.reconcile = true
            self.processPending(reason: "lifecycle")
            self.scheduleMaintenance()
        }
    }

    private func startWatcher() {
        watcherRevision &+= 1
        let current = generation, revision = watcherRevision
        let wasWatching = watching
        watching = watcher.start { [weak self] changes in
            Task { @MainActor [weak self] in
                guard let self, self.generation == current, self.watcherRevision == revision else { return }
                self.receive(changes)
            }
        }
        if !watching { watcherFailures = min(watcherFailures, Int64.max - 1) + 1 }
        else if !wasWatching, watcherFailures > 0 { recoveries = min(recoveries, Int64.max - 1) + 1 }
        nextRetry = Date().addingTimeInterval(timing.retry)
        diagnostics.updateContext(["activity_watcher": .string(watching ? "watching" : "fallback")])
        diagnostics.record(.operation, fields: ["operation": .string("activityWatcher"),
            "phase": .string(watching ? "started" : "failed"),
            "watcherFailures": .int(watcherFailures), "recoveryCount": .int(recoveries)])
    }

    func receive(_ changes: ActivityFileChanges) {
        guard continuation != nil, !sleeping else { return }
        if changes.restart {
            startWatcher()
            scheduleMaintenance()
        }
        // Keep the watcher installed while Codex is closed, but do no file I/O.
        guard !ready || launchDate != nil else { return }
        pending.merge(changes)
        if changes.reconcile { processPending(reason: "recovery") }
        else { scheduleBatch() }
    }

    private func scheduleBatch(after delay: TimeInterval? = nil) {
        guard ready, !sleeping, continuation != nil, readTask == nil, batchTask == nil, !pending.isEmpty else { return }
        let current = generation, revision = environmentRevision
        let delay = delay ?? timing.batch
        batchTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, delay))) } catch { return }
            guard let self, self.generation == current, self.environmentRevision == revision else { return }
            self.batchTask = nil
            self.processPending(reason: "event")
        }
    }

    private func processPending(reason: String) {
        guard ready, !sleeping, continuation != nil, readTask == nil, !pending.isEmpty else { return }
        batchTask?.cancel(); batchTask = nil
        var changes = pending
        pending = ActivityFileChanges()
        let untilCatalog = timing.catalog - Date().timeIntervalSince(lastCatalog)
        if changes.catalog && !changes.reconcile && untilCatalog > 0 {
            changes.catalog = false
            pending.catalog = true
            if changes.paths.isEmpty { scheduleBatch(after: untilCatalog); return }
        }
        if changes.catalog || changes.reconcile { lastCatalog = Date() }
        if changes.reconcile {
            reconciliations = min(reconciliations, Int64.max - 1) + 1
            diagnostics.record(.operation, fields: ["operation": .string("activityReconcile"),
                "reason": .string(reason), "reconcileCount": .int(reconciliations)])
        }
        // A pending expiry must not publish an older classification after this
        // read. Its replacement deadline comes from the refreshed cache.
        expiryTask?.cancel(); expiryTask = nil
        let current = generation, revision = environmentRevision
        let launch = launchDate, reader = reader
        readTask = Task { [weak self] in
            let result = await reader.refresh(paths: changes.reconcile ? nil : changes.paths,
                refreshCatalog: changes.catalog || changes.reconcile, launchDate: launch, reason: reason)
            guard !Task.isCancelled, let self, self.generation == current,
                  self.environmentRevision == revision, !self.sleeping else { return }
            self.readTask = nil
            if self.watching, let targets = result.watchTargets {
                let update = self.watcher.updateTargets(targets)
                if update.failed {
                    self.watcherRevision &+= 1
                    self.watcher.stop()
                    self.watching = false
                    self.watcherFailures = min(self.watcherFailures, Int64.max - 1) + 1
                    self.nextRetry = Date().addingTimeInterval(self.timing.retry)
                    self.diagnostics.updateContext(["activity_watcher": .string("fallback")])
                    self.diagnostics.record(.operation, fields: ["operation": .string("activityWatcher"),
                        "phase": .string("failed"), "watcherFailures": .int(self.watcherFailures),
                        "recoveryCount": .int(self.recoveries)])
                    self.scheduleMaintenance()
                } else { self.pending.merge(update.changes) }
            }
            if result.catalogNeeded { self.pending.catalog = true }
            self.updateCatalogRecovery(unavailable: result.catalogUnavailable)
            self.publish(result)
            self.scheduleBatch(after: self.pending.catalog && self.pending.paths.isEmpty
                ? max(self.timing.batch, self.timing.catalog - Date().timeIntervalSince(self.lastCatalog)) : nil)
        }
    }

    private func updateCatalogRecovery(unavailable: Bool) {
        guard unavailable else {
            catalogRetryTask?.cancel(); catalogRetryTask = nil
            catalogRetryDelay = 0
            return
        }
        guard catalogRetryTask == nil, launchDate != nil else { return }
        let minimum = max(0.001, timing.catalogRetry)
        let maximum = max(minimum, timing.catalogRetryMaximum)
        catalogRetryDelay = min(maximum, max(minimum, catalogRetryDelay * 2))
        let delay = catalogRetryDelay
        let current = generation, revision = environmentRevision
        catalogRetryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled, let self, self.generation == current,
                  self.environmentRevision == revision, !self.sleeping else { return }
            self.catalogRetryTask = nil
            self.pending.catalog = true
            self.processPending(reason: "catalogRetry")
        }
    }

    private func publish(_ result: ActivityRefresh) {
        let value = result.snapshot
        if lastSnapshot?.isWorking != value.isWorking || lastSnapshot?.isAvailable != value.isAvailable
            || lastSnapshot?.activeTaskCount != value.activeTaskCount || lastSnapshot?.detail != value.detail {
            lastSnapshot = value
            continuation?.yield(value)
        }
        expiryTask?.cancel(); expiryTask = nil
        guard let deadline = result.nextExpiry else { return }
        let current = generation, revision = environmentRevision, reader = reader
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0.001, deadline.timeIntervalSinceNow))) } catch { return }
            let result = await reader.reclassify()
            guard !Task.isCancelled, let self, self.generation == current,
                  self.environmentRevision == revision, !self.sleeping else { return }
            self.publish(result)
        }
    }

    private func scheduleMaintenance() {
        maintenanceTask?.cancel(); maintenanceTask = nil
        guard ready, launchDate != nil, !sleeping, continuation != nil else { return }
        let current = generation, revision = environmentRevision
        let interval = watching ? timing.safety : min(timing.fallback, max(0.001, nextRetry.timeIntervalSinceNow))
        let tolerance = watching ? timing.tolerance : 0.1
        maintenanceTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(interval), tolerance: .seconds(tolerance)) } catch { return }
            guard let self, self.generation == current, self.environmentRevision == revision else { return }
            self.maintenanceTask = nil
            if !self.watching, Date() >= self.nextRetry { self.startWatcher() }
            self.pending.reconcile = true
            self.processPending(reason: self.watching ? "safety" : "fallback")
            self.scheduleMaintenance()
        }
    }
}
