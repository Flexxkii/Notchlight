import CodexIntegration
import Foundation
import WidgetKit
import WidgetShared
import Diagnostics

@MainActor
final class WidgetSnapshotPublisher {
    private let writer: WidgetSnapshotWriter?
    private var pending: Task<Void, Never>?

    init(diagnostics: DiagnosticRecorder = .disabled) {
        // App-group resolution calls Security.framework. Resolve it on the
        // writer actor rather than blocking SwiftUI's main-actor initialization.
        writer = WidgetSnapshotWriter(store: nil, diagnostics: diagnostics, resolveAppGroup: true)
    }

    init(store: WidgetSnapshotStore?, diagnostics: DiagnosticRecorder = .disabled) {
        writer = store.map { WidgetSnapshotWriter(store: $0, diagnostics: diagnostics) }
    }

    func publish(linked: Bool, monitor: CodexMonitor, selected: CodexUsageWindow) {
        guard let writer else { return }
        let connection: WidgetConnection
        if !linked { connection = .disconnected }
        else if monitor.usageFailure == .signInRequired { connection = .signInRequired }
        else if monitor.usage != nil { connection = monitor.usageError == nil ? .connected : .stale }
        else if monitor.usageError != nil { connection = .unavailable }
        else { connection = .loading }
        let activity = monitor.widgetActivity
        let snapshot = WidgetSnapshot(
            connection: connection,
            allowances: linked ? (monitor.usage?.windows ?? []).map {
                WidgetAllowance(usedPercent: $0.usedPercent, durationMinutes: $0.windowDurationMins,
                                resetsAt: $0.resetsAt, isCalendarMonth: $0.isCalendarMonth)
            } : [],
            selectedWindow: selected.rawValue,
            sampledAt: linked ? monitor.usage?.sampledAt : nil,
            activity: linked && activity?.isAvailable == true ? (activity?.isWorking == true ? .working : .idle) : .unavailable,
            activitySampledAt: linked ? activity?.sampledAt : nil)
        let previous = pending
        pending = Task {
            await previous?.value
            if await writer.write(snapshot) { WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.kind) }
        }
    }

    func flush() async { await pending?.value }
}

private actor WidgetSnapshotWriter {
    var store: WidgetSnapshotStore?
    let resolveAppGroup: Bool
    var resolvedStore = false
    let diagnostics: DiagnosticRecorder
    var previous: WidgetSnapshot?
    var lastReload: Date = .distantPast

    init(store: WidgetSnapshotStore?, diagnostics: DiagnosticRecorder, resolveAppGroup: Bool = false) {
        self.store = store
        self.diagnostics = diagnostics
        self.resolveAppGroup = resolveAppGroup
    }

    func write(_ snapshot: WidgetSnapshot) -> Bool {
        if !resolvedStore {
            if resolveAppGroup { store = .appGroup() }
            resolvedStore = true
        }
        guard let store else { return false }
        let meaningfulChange = previous?.connection != snapshot.connection
            || previous?.allowances != snapshot.allowances
            || previous?.selectedWindow != snapshot.selectedWindow
            || previous?.activity != snapshot.activity
        guard meaningfulChange || previous?.sampledAt != snapshot.sampledAt
                || snapshot.writtenAt.timeIntervalSince(previous?.writtenAt ?? .distantPast) >= 60 else { return false }
        do { try store.write(snapshot) } catch {
            diagnostics.record(.failure, fields: ["operation": .string("widgetSnapshot"), "category": .string("storage")])
            return false
        }
        previous = snapshot
        // Renew expiry timelines without a reload request on every activity sample.
        guard meaningfulChange || snapshot.writtenAt.timeIntervalSince(lastReload) >= 240 else { return false }
        lastReload = snapshot.writtenAt
        return true
    }
}
