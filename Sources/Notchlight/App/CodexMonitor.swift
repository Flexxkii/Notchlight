import AppKit
import CodexIntegration
import Foundation
import Observation
import Diagnostics

@MainActor
@Observable
final class CodexMonitor {
    private(set) var usage: CodexUsageSnapshot?
    private(set) var usageError: String?
    private(set) var usageFailure: CodexUsageError?
    private(set) var activity: CodexActivitySnapshot?
    private(set) var isRefreshing = false
    private(set) var isMonitoring = false

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onWidgetChange: (() -> Void)?
    @ObservationIgnored private(set) var widgetActivity: CodexActivitySnapshot?
    @ObservationIgnored private let accountObserver: CodexAccountChangeObserver
    @ObservationIgnored private let readUsage: @Sendable () async -> CodexUsageReadResult
    @ObservationIgnored private let activityObservation: CodexActivityObservation
    @ObservationIgnored private let diagnostics: DiagnosticRecorder
    @ObservationIgnored private var usageTask: Task<Void, Never>?
    @ObservationIgnored private var activityTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var usageGeneration = 0
    @ObservationIgnored private var sleeping = false
    @ObservationIgnored private let workspaceNotificationCenter: NotificationCenter
    @ObservationIgnored private var systemObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var accountFingerprint: String?
    @ObservationIgnored private var nextUsageRefresh = Date.distantPast

    var isWorking: Bool { activity?.isAvailable == true && activity?.isWorking == true }

    init(diagnostics: DiagnosticRecorder = .disabled, codexHome: URL? = nil,
         workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         readUsage: (@Sendable () async -> CodexUsageReadResult)? = nil) {
        self.diagnostics = diagnostics
        self.workspaceNotificationCenter = workspaceNotificationCenter
        let reader = CodexUsageReader(diagnostics: diagnostics)
        self.readUsage = readUsage ?? { await reader.readAccountAware() }
        accountObserver = CodexAccountChangeObserver(root: codexHome)
        activityObservation = CodexActivityObservation(diagnostics: diagnostics, codexHome: codexHome)
        for (name, asleep) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)] {
            systemObservers.append(workspaceNotificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSleeping(asleep) }
            })
        }
    }

    isolated deinit {
        stop()
        for observer in systemObservers { workspaceNotificationCenter.removeObserver(observer) }
    }

    private func setSleeping(_ value: Bool) {
        guard sleeping != value else { return }
        sleeping = value
        // A separate epoch invalidates usage work without interrupting the
        // activity subscription or discarding the last successful account data.
        usageGeneration &+= 1
        usageTask?.cancel(); usageTask = nil
        refreshTask?.cancel(); refreshTask = nil
        nextUsageRefresh = .distantPast
        isRefreshing = false
        diagnostics.updateContext(["usage_refreshing": .bool(false)])
        if !sleeping, isMonitoring { scheduleUsageRefresh(after: 0) }
        onChange?()
    }

    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true
        accountObserver.start { [weak self] in self?.invalidateAccount() }
        onChange?()
        diagnostics.updateContext(["codex_monitoring": .bool(true)])
        generation += 1
        let current = generation
        scheduleUsageRefresh(after: 0)
        let activityStream = activityObservation.snapshots(includeFreshness: true)
        activityTask = Task { [weak self] in
            for await snapshot in activityStream {
                guard !Task.isCancelled, let self, self.generation == current else { return }
                self.recordActivity(snapshot)
            }
        }
    }

    func stop() {
        generation += 1
        usageGeneration &+= 1
        usageTask?.cancel()
        activityTask?.cancel()
        activityObservation.stop()
        accountObserver.stop()
        refreshTask?.cancel()
        usageTask = nil
        nextUsageRefresh = .distantPast
        activityTask = nil
        refreshTask = nil
        isMonitoring = false
        diagnostics.updateContext(["codex_monitoring": .bool(false), "usage_refreshing": .bool(false)])
        isRefreshing = false
        usage = nil
        usageError = nil
        usageFailure = nil
        activity = nil
        widgetActivity = nil
        accountFingerprint = nil
        onChange?()
    }

    func refresh() {
        guard isMonitoring, !sleeping, !isRefreshing else { return }
        let current = generation, usageEpoch = usageGeneration
        refreshTask = Task { [weak self] in
            await self?.refreshUsage(generation: current, usageEpoch: usageEpoch)
        }
    }

    func recordUsage(_ snapshot: CodexUsageSnapshot) {
        usage = snapshot
        usageError = nil
        usageFailure = nil
        onChange?()
    }

    func recordRead(_ result: CodexUsageReadResult) {
        if let previous = accountFingerprint, let next = result.accountFingerprint, previous != next {
            usage = nil
            activity = nil
            widgetActivity = nil
        }
        if let next = result.accountFingerprint { accountFingerprint = next }
        switch result.usage {
        case .success(let snapshot): recordUsage(snapshot)
        case .failure(let failure): recordFailure(failure)
        }
    }

    func recordFailure(_ failure: CodexUsageError) {
        usageFailure = failure
        if failure == .signInRequired || failure == .incompatibleAccount { usage = nil; widgetActivity = nil }
        usageError = failure.localizedDescription
        onChange?()
    }

    func recordActivity(_ snapshot: CodexActivitySnapshot) {
        widgetActivity = snapshot
        onWidgetChange?()
        let changed = activity?.isWorking != snapshot.isWorking
            || activity?.isAvailable != snapshot.isAvailable
            || activity?.activeTaskCount != snapshot.activeTaskCount
            || activity?.detail != snapshot.detail
        guard changed else { return }
        activity = snapshot
        if isMonitoring, !isRefreshing, isWorking,
           nextUsageRefresh.timeIntervalSinceNow > 60 {
            scheduleUsageRefresh(after: max(0, 60 - Date().timeIntervalSince(usage?.sampledAt ?? .distantPast)))
        }
        onChange?()
    }

    private func scheduleUsageRefresh(after delay: TimeInterval) {
        usageTask?.cancel()
        guard isMonitoring, !sleeping else { usageTask = nil; return }
        nextUsageRefresh = Date().addingTimeInterval(delay)
        let current = generation, usageEpoch = usageGeneration
        usageTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.generation == current, !Task.isCancelled else { return }
            await self.refreshUsage(generation: current, usageEpoch: usageEpoch)
        }
    }

    private func refreshUsage(generation current: Int, usageEpoch: Int) async {
        guard isMonitoring, !sleeping, !isRefreshing, !Task.isCancelled,
              generation == current, usageGeneration == usageEpoch else { return }
        isRefreshing = true
        let accountRevision = accountObserver.revision
        let interval = diagnostics.beginInterval(.usageRefresh)
        var outcome: DiagnosticOutcome = .success
        diagnostics.updateContext(["usage_refreshing": .bool(true)])
        defer {
            diagnostics.endInterval(interval, outcome: outcome)
            if generation == current, usageGeneration == usageEpoch {
                isRefreshing = false
                diagnostics.updateContext(["usage_refreshing": .bool(false)])
                scheduleUsageRefresh(after: UsageRefreshPolicy.delay(
                    working: isWorking, activityAvailable: activity?.isAvailable == true,
                    hasUsage: usage != nil, failed: usageError != nil))
            }
        }
        let result = await readUsage()
        guard !Task.isCancelled, generation == current, usageGeneration == usageEpoch else { outcome = .cancelled; return }
        guard accountRevision == accountObserver.revision else { invalidateAccount(); return }
        if case .failure(let usageFailure) = result.usage {
            outcome = .failed
            diagnostics.record(.failure, fields: [
                "operation": .string("usageRefresh"),
                "category": .string(String(describing: usageFailure))
            ])
            if usageFailure == .timedOut { outcome = .timedOut }
            if usageFailure == .cancelled { outcome = .cancelled }
        }
        recordRead(result)
    }

    /// Drops cached values and in-flight reads from the previous account.
    func invalidateAccount() {
        let wasMonitoring = isMonitoring
        stop()
        if wasMonitoring { start() }
    }
}
