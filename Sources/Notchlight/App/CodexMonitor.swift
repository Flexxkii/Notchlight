import CodexIntegration
import Foundation
import Observation
import Diagnostics

@MainActor
@Observable
final class CodexMonitor {
    private(set) var usage: CodexUsageSnapshot?
    private(set) var usageError: String?
    private(set) var activity: CodexActivitySnapshot?
    private(set) var isRefreshing = false
    private(set) var isMonitoring = false

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let usageReader: CodexUsageReader
    @ObservationIgnored private let activityReader: CodexActivityReader
    @ObservationIgnored private let diagnostics: DiagnosticRecorder
    @ObservationIgnored private var usageTask: Task<Void, Never>?
    @ObservationIgnored private var activityTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    var isWorking: Bool { activity?.isAvailable == true && activity?.isWorking == true }

    init(diagnostics: DiagnosticRecorder = .disabled) {
        self.diagnostics = diagnostics
        usageReader = CodexUsageReader(diagnostics: diagnostics)
        activityReader = CodexActivityReader(diagnostics: diagnostics)
    }

    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true
        diagnostics.updateContext(["codex_monitoring": .bool(true)])
        generation += 1
        let current = generation
        usageTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == current else { return }
                await self.refreshUsage(generation: current)
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        activityTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == current else { return }
                let snapshot = await self.activityReader.read()
                guard !Task.isCancelled, self.generation == current else { return }
                self.recordActivity(snapshot)
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    func stop() {
        generation += 1
        usageTask?.cancel()
        activityTask?.cancel()
        refreshTask?.cancel()
        usageTask = nil
        activityTask = nil
        refreshTask = nil
        isMonitoring = false
        diagnostics.updateContext(["codex_monitoring": .bool(false), "usage_refreshing": .bool(false)])
        isRefreshing = false
        usage = nil
        usageError = nil
        activity = nil
        onChange?()
    }

    func refresh() {
        guard isMonitoring, !isRefreshing else { return }
        let current = generation
        refreshTask = Task { [weak self] in
            await self?.refreshUsage(generation: current)
        }
    }

    func recordUsage(_ snapshot: CodexUsageSnapshot) {
        usage = snapshot
        usageError = nil
        onChange?()
    }

    func recordActivity(_ snapshot: CodexActivitySnapshot) {
        let changed = activity?.isWorking != snapshot.isWorking
            || activity?.isAvailable != snapshot.isAvailable
            || activity?.activeTaskCount != snapshot.activeTaskCount
            || activity?.detail != snapshot.detail
        activity = snapshot
        if changed { onChange?() }
    }

    private func refreshUsage(generation current: Int) async {
        guard !isRefreshing, generation == current else { return }
        isRefreshing = true
        let interval = diagnostics.beginInterval(.usageRefresh)
        var outcome: DiagnosticOutcome = .success
        diagnostics.updateContext(["usage_refreshing": .bool(true)])
        defer {
            diagnostics.endInterval(interval, outcome: outcome)
            if generation == current {
                isRefreshing = false
                diagnostics.updateContext(["usage_refreshing": .bool(false)])
            }
        }
        do {
            let snapshot = try await usageReader.read()
            guard !Task.isCancelled, generation == current else { outcome = .cancelled; return }
            recordUsage(snapshot)
        } catch {
            outcome = .failed
            guard !Task.isCancelled, generation == current else { outcome = .cancelled; return }
            let usageFailure = error as? CodexUsageError
            diagnostics.record(.failure, fields: [
                "operation": .string("usageRefresh"),
                "category": .string(usageFailure.map { String(describing: $0) } ?? "unknown")
            ])
            if case .timedOut? = usageFailure { outcome = .timedOut }
            if case .cancelled? = usageFailure { outcome = .cancelled }
            switch usageFailure {
            case .signInRequired?, .incompatibleAccount?: usage = nil
            default: break
            }
            usageError = usageFailure?.localizedDescription ?? "Codex usage is unavailable. Try refreshing."
            // A failed refresh is not a fresh zero-percent measurement.
            onChange?()
        }
    }
}
