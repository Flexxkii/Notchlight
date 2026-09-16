import Foundation
import Testing
@testable import Notchlight

@MainActor
struct SwipeSettingsTests {
    @Test("swipe visibility preference defaults off and persists")
    func preferencePersistence() throws {
        let suite = "SwipeSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "border.enabled")

        let model = BorderModel(defaults: defaults, startIntegration: false, startOverlay: false)
        #expect(model.hideWhenSwiping == false)
        #expect(model.swipeMonitoringStatus == .disabled)
        model.hideWhenSwiping = true
        model.hideWhenSwiping = false
        #expect(model.hideWhenSwiping == false)

        let restored = BorderModel(defaults: defaults, startIntegration: false, startOverlay: false)
        #expect(restored.hideWhenSwiping == false)
        #expect(restored.swipeMonitoringStatus == .disabled)

        restored.hideWhenSwiping = true
        restored.resetAppearance()
        #expect(restored.hideWhenSwiping)
    }

    @Test("permission actions are inert when overlay services are disabled")
    func disabledOverlayDoesNotPrompt() throws {
        let suite = "SwipeSettingsTests.disabled.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "border.enabled")
        let model = BorderModel(defaults: defaults, startIntegration: false, startOverlay: false)

        model.requestSwipeMonitoringPermission()
        model.refreshSwipeMonitoring()
        #expect(model.swipeMonitoringStatus == .disabled)
    }
}
