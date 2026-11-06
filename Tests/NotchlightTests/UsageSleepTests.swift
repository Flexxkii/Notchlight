import AppKit
import CodexIntegration
import Testing
@testable import Notchlight

@MainActor
struct UsageSleepTests {
    @Test("sleep cancels a read, preserves usage, and rejects late results after wake")
    func inFlightSleepAndWake() async throws {
        let fixture = try SleepFixture()
        defer { fixture.close() }
        let monitor = fixture.monitor, probe = fixture.probe
        monitor.recordUsage(SleepFixture.snapshot(42))
        monitor.start()
        try await wait { await probe.calls == 1 }
        fixture.post(NSWorkspace.willSleepNotification)
        try await wait { await probe.cancelled.contains(1) }
        #expect(!monitor.isRefreshing)
        #expect(monitor.usage?.windows.first?.usedPercent == 42)
        #expect(monitor.usageError == nil)

        monitor.refresh()
        try await Task.sleep(for: .milliseconds(40))
        #expect(await probe.calls == 1)
        fixture.post(NSWorkspace.didWakeNotification)
        fixture.post(NSWorkspace.didWakeNotification)
        try await wait { await probe.calls == 2 }
        await probe.finish(1, percent: 99) // Intentionally ignores cancellation.
        try await Task.sleep(for: .milliseconds(40))
        #expect(monitor.isRefreshing)
        #expect(monitor.usage?.windows.first?.usedPercent == 42)
        #expect(monitor.usageError == nil)
        await probe.finish(2, percent: 43)
        try await wait { monitor.usage?.windows.first?.usedPercent == 43 && !monitor.isRefreshing }
        #expect(await probe.calls == 2)
    }

    @Test("start, account invalidation, and manual refresh cannot launch a helper while asleep")
    func asleepBeforeStart() async throws {
        let fixture = try SleepFixture()
        defer { fixture.close() }
        let monitor = fixture.monitor, probe = fixture.probe
        fixture.post(NSWorkspace.willSleepNotification)
        monitor.start()
        monitor.invalidateAccount()
        monitor.refresh()
        monitor.recordActivity(.init(isWorking: true, activeTaskCount: 1, isAvailable: true,
                                     detail: "Working", sampledAt: .now))
        try await Task.sleep(for: .milliseconds(80))
        #expect(await probe.calls == 0)
        fixture.post(NSWorkspace.didWakeNotification)
        try await wait { await probe.calls == 1 }
        await probe.finish(1, percent: 24)
        try await wait { monitor.usage != nil }
        monitor.stop()
        fixture.post(NSWorkspace.willSleepNotification)
        fixture.post(NSWorkspace.didWakeNotification)
        try await Task.sleep(for: .milliseconds(40))
        #expect(await probe.calls == 1)
    }

    @Test("sleep before a queued manual refresh starts suppresses that request")
    func queuedRefresh() async throws {
        let fixture = try SleepFixture()
        defer { fixture.close() }
        fixture.monitor.start()
        try await wait { await fixture.probe.calls == 1 }
        await fixture.probe.finish(1, percent: 31)
        try await wait { !fixture.monitor.isRefreshing }
        fixture.monitor.refresh()
        fixture.post(NSWorkspace.willSleepNotification)
        try await Task.sleep(for: .milliseconds(80))
        #expect(await fixture.probe.calls == 1)
        #expect(fixture.monitor.usage?.windows.first?.usedPercent == 31)
        fixture.post(NSWorkspace.didWakeNotification)
        try await wait { await fixture.probe.calls == 2 }
        await fixture.probe.finish(2, percent: 32)
        try await wait { fixture.monitor.usage?.windows.first?.usedPercent == 32 }
    }

    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            if ContinuousClock.now >= deadline { throw SleepError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor UsageProbe {
    private(set) var calls = 0
    private(set) var cancelled: Set<Int> = []
    private var continuations: [Int: CheckedContinuation<CodexUsageReadResult, Never>] = [:]

    func read() async -> CodexUsageReadResult {
        calls += 1
        let call = calls
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuations[call] = $0 }
        } onCancel: {
            Task { await self.markCancelled(call) }
        }
    }

    private func markCancelled(_ call: Int) { cancelled.insert(call) }
    func finish(_ call: Int, percent: Double) {
        continuations.removeValue(forKey: call)?.resume(returning:
            .init(accountFingerprint: "fixture", usage: .success(SleepFixture.snapshot(percent))))
    }
    func finishAll() {
        for continuation in continuations.values {
            continuation.resume(returning: .init(accountFingerprint: nil, usage: .failure(.cancelled)))
        }
        continuations.removeAll()
    }
}

@MainActor
private final class SleepFixture {
    let root: URL
    let center = NotificationCenter()
    let probe = UsageProbe()
    let monitor: CodexMonitor

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-sleep-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let probe = probe
        monitor = CodexMonitor(codexHome: root, workspaceNotificationCenter: center, readUsage: { await probe.read() })
    }
    func post(_ name: Notification.Name) { center.post(name: name, object: nil) }
    func close() {
        monitor.stop()
        let probe = probe
        Task { await probe.finishAll() }
        try? FileManager.default.removeItem(at: root)
    }
    nonisolated static func snapshot(_ percent: Double) -> CodexUsageSnapshot {
        .init(windows: [.init(usedPercent: percent, windowDurationMins: 300, resetsAt: nil)], sampledAt: .now)
    }
}
private enum SleepError: Error { case timeout }
