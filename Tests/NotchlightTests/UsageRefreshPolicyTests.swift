import Testing
@testable import Notchlight

struct UsageRefreshPolicyTests {
    @Test func healthyIdleReducesHelperLaunches() {
        #expect(UsageRefreshPolicy.delay(working: false, activityAvailable: true, hasUsage: true, failed: false) == 300)
    }

    @Test func activeWorkAndRecoveryStayFresh() {
        #expect(UsageRefreshPolicy.delay(working: true, activityAvailable: true, hasUsage: true, failed: false) == 60)
        #expect(UsageRefreshPolicy.delay(working: false, activityAvailable: false, hasUsage: true, failed: false) == 60)
        #expect(UsageRefreshPolicy.delay(working: false, activityAvailable: true, hasUsage: false, failed: false) == 60)
        #expect(UsageRefreshPolicy.delay(working: false, activityAvailable: true, hasUsage: true, failed: true) == 60)
    }
}
