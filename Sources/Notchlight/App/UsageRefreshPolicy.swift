import Foundation

enum UsageRefreshPolicy {
    static func delay(working: Bool, activityAvailable: Bool, hasUsage: Bool, failed: Bool) -> TimeInterval {
        // Keep recovery and active work fresh, without launching a helper every
        // minute merely to reconfirm unchanged allowances during healthy idle.
        working || !activityAvailable || !hasUsage || failed ? 60 : 300
    }
}
