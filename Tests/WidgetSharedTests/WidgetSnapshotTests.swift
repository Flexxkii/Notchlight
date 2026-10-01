import Foundation
import Testing
@testable import WidgetShared

struct WidgetSnapshotTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func allowance(_ minutes: Int = 300, used: Double = 24, reset: Date? = nil, monthly: Bool = false) -> WidgetAllowance {
        WidgetAllowance(usedPercent: used, durationMinutes: minutes, resetsAt: reset, isCalendarMonth: monthly)
    }

    @Test func selectionUsesAvailableWindows() {
        let monthly = allowance(44_640, monthly: true)
        var snapshot = WidgetSnapshot(connection: .connected, allowances: [monthly], sampledAt: now)
        #expect(snapshot.displayedAllowances(medium: false, at: now) == [monthly])
        #expect(snapshot.displayedAllowances(medium: true, at: now) == [monthly])
        snapshot.allowances = [monthly, allowance(10_080), allowance()]
        #expect(snapshot.displayedAllowances(medium: true, at: now).map(\.durationMinutes) == [300, 10_080])
        snapshot.selectedWindow = "monthly"
        #expect(snapshot.displayedAllowances(medium: false, at: now) == [monthly])
        snapshot.selectedWindow = "weekly"
        #expect(snapshot.displayedAllowances(medium: false, at: now).first?.durationMinutes == 10_080)
        snapshot.allowances = [allowance(10_080)]
        snapshot.selectedWindow = "monthly"
        #expect(snapshot.displayedAllowances(medium: false, at: now).first?.name == "Weekly")
        #expect(allowance(43_200).name == "30-day")
        #expect(monthly.name == "Monthly")
    }

    @Test func percentageBoundaries() {
        #expect(allowance(used: -1).remaining == 100)
        #expect(allowance(used: 101).remaining == 0)
        #expect(allowance(used: 0).remaining == 100)
        #expect(allowance(used: 100).remaining == 0)
        #expect(allowance(used: 24).remaining == 76)
        for invalid in [Double.nan, .infinity, -.infinity] {
            #expect(allowance(used: invalid).remaining == nil)
            #expect(WidgetSnapshot(connection: .connected, allowances: [allowance(used: invalid)], sampledAt: now).state(at: now) == .unavailable)
        }
    }

    @Test func freshnessAndExpiredResets() {
        var snapshot = WidgetSnapshot(connection: .connected, allowances: [allowance()], sampledAt: now,
                                      activity: .working, activitySampledAt: now, writtenAt: now)
        #expect(snapshot.currentActivity(at: now) == .working)
        #expect(snapshot.currentActivity(at: now.addingTimeInterval(300)) == .unavailable)
        #expect(snapshot.state(at: now.addingTimeInterval(900)) == .stale)
        snapshot.activity = .idle
        #expect(snapshot.currentActivity(at: now) == .idle)
        snapshot.activitySampledAt = nil
        #expect(snapshot.currentActivity(at: now) == .unavailable)
        snapshot.sampledAt = now.addingTimeInterval(60)
        #expect(snapshot.state(at: now) == .stale)
        snapshot.sampledAt = now
        snapshot.allowances = [allowance(reset: now)]
        #expect(snapshot.state(at: now) == .stale)
        #expect(snapshot.allowances[0].resetText(at: now) == "Awaiting update")
        #expect(allowance().resetText(at: now) == "Reset unavailable")
        #expect(allowance(reset: now.addingTimeInterval(20)).resetText(at: now) == "Resets in <1m")
        #expect(allowance(reset: now.addingTimeInterval(3600)).resetText(at: now).contains("1h"))
    }

    @Test func disconnectedAndSignInCannotExposeCachedValues() {
        for state in [WidgetConnection.disconnected, .signInRequired, .loading, .unavailable] {
            let snapshot = WidgetSnapshot(connection: state, allowances: [allowance()], sampledAt: now,
                                          activity: .working, activitySampledAt: now, writtenAt: now)
            #expect(snapshot.displayedAllowances(medium: true, at: now).isEmpty)
            #expect(snapshot.currentActivity(at: now) == .unavailable)
            #expect(snapshot.state(at: now) == state)
        }
        let stale = WidgetSnapshot(connection: .stale, allowances: [allowance()], sampledAt: now)
        #expect(stale.displayedAllowances(medium: false, at: now).first?.remaining == 76)
        #expect(stale.statusText(at: now).contains("Stale"))
    }

    @Test func storeRoundTripAndReplacement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WidgetSnapshotStore(directory: directory)
        #expect(store.read().connection == .unavailable)
        var snapshot = WidgetSnapshot(connection: .connected, allowances: [allowance(reset: now.addingTimeInterval(600))], sampledAt: now)
        try store.write(snapshot)
        #expect(store.read() == snapshot)
        #expect(snapshot.timelineDates(from: now).contains(now.addingTimeInterval(600)))
        try store.write(WidgetSnapshot(connection: .disconnected))
        #expect(store.read().allowances.isEmpty)
        snapshot.version = 99
        try store.write(snapshot)
        #expect(store.read().connection == .unavailable)
        try Data("bad-json".utf8).write(to: store.url)
        #expect(store.read().connection == .unavailable)
    }
}
