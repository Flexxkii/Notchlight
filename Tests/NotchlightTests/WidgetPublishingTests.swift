import CodexIntegration
import Foundation
import Testing
import WidgetShared
@testable import Notchlight

@MainActor
struct WidgetPublishingTests {
    @Test func publisherPreservesOrderingAndClearsPersistentValues() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WidgetSnapshotStore(directory: directory)
        let publisher = WidgetSnapshotPublisher(store: store)
        let monitor = CodexMonitor()
        monitor.recordUsage(.init(windows: [.init(usedPercent: 24, windowDurationMins: 10_080, resetsAt: nil)], sampledAt: .now))
        publisher.publish(linked: true, monitor: monitor, selected: .weekly)
        await publisher.flush()
        #expect(store.read().allowances.first?.remaining == 76)
        monitor.recordFailure(.timedOut)
        publisher.publish(linked: true, monitor: monitor, selected: .weekly)
        await publisher.flush()
        #expect(store.read().connection == .stale)
        #expect(store.read().allowances.first?.remaining == 76)
        publisher.publish(linked: true, monitor: monitor, selected: .weekly)
        publisher.publish(linked: false, monitor: monitor, selected: .weekly)
        await publisher.flush()
        #expect(store.read().connection == .disconnected)
        #expect(store.read().allowances.isEmpty)
        #expect(store.read().sampledAt == nil)
        monitor.invalidateAccount()
        publisher.publish(linked: true, monitor: monitor, selected: .weekly)
        await publisher.flush()
        #expect(store.read().connection == .loading)
        #expect(store.read().allowances.isEmpty)
    }

    @Test func widgetOpeningRoutesColdAndWarmLaunches() {
        let delegate = AppDelegate()
        var opened = 0
        delegate.handleUsageURLs([WidgetSnapshot.settingsURL])
        delegate.onOpenUsage = { opened += 1 }
        #expect(opened == 1)
        delegate.handleUsageURLs([WidgetSnapshot.settingsURL])
        #expect(opened == 2)
        delegate.handleUsageURLs([URL(string: "notchlight://unrelated")!])
        #expect(opened == 2)
    }

    @Test func failuresKeepOnlySameAccountValues() {
        let monitor = CodexMonitor()
        let usage = CodexUsageSnapshot(windows: [.init(usedPercent: 42, windowDurationMins: 300, resetsAt: nil)], sampledAt: .now)
        monitor.recordRead(.init(accountFingerprint: "first", usage: .success(usage)))
        monitor.recordRead(.init(accountFingerprint: "first", usage: .failure(.timedOut)))
        #expect(monitor.usage?.windows.first?.usedPercent == 42)
        #expect(monitor.usageFailure == .timedOut)
        monitor.recordRead(.init(accountFingerprint: nil, usage: .failure(.launchFailed)))
        #expect(monitor.usage?.windows.first?.usedPercent == 42)
        monitor.recordRead(.init(accountFingerprint: "second", usage: .failure(.protocolFailure)))
        #expect(monitor.usage == nil)
        monitor.recordRead(.init(accountFingerprint: "second", usage: .success(usage)))
        monitor.recordFailure(.signInRequired)
        #expect(monitor.usage == nil)
        monitor.recordUsage(usage)
        monitor.invalidateAccount()
        #expect(monitor.usage == nil)
        #expect(monitor.widgetActivity == nil)
        monitor.recordUsage(usage)
        monitor.stop()
        #expect(monitor.usage == nil)
    }

    @Test func activityFreshnessDoesNotInvalidateOverlay() {
        let monitor = CodexMonitor()
        var overlayChanges = 0
        var widgetChanges = 0
        monitor.onChange = { overlayChanges += 1 }
        monitor.onWidgetChange = { widgetChanges += 1 }
        let now = Date()
        for offset in [0.0, 60.0] {
            monitor.recordActivity(.init(isWorking: true, activeTaskCount: 1, isAvailable: true,
                                        detail: "Working", sampledAt: now.addingTimeInterval(offset)))
        }
        #expect(overlayChanges == 1)
        #expect(widgetChanges == 2)
        #expect(monitor.widgetActivity?.sampledAt == now.addingTimeInterval(60))
    }
}
