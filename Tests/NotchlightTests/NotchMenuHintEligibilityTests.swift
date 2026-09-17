import Foundation
import Testing
@testable import Notchlight

@MainActor
struct NotchMenuHintEligibilityTests {
    @Test("fresh installs remain eligible until discovery, including across a launch without a notch")
    func persistsDiscovery() throws {
        let name = "NotchMenuHintTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = NotchMenuHintEligibility(defaults: defaults, hasUsedAppBefore: false)
        #expect(first.shouldOffer)
        defaults.set(true, forKey: "border.enabled")
        let relaunched = NotchMenuHintEligibility(defaults: defaults, hasUsedAppBefore: true)
        #expect(relaunched.shouldOffer)
        relaunched.complete()
        #expect(!NotchMenuHintEligibility(defaults: defaults, hasUsedAppBefore: true).shouldOffer)
    }

    @Test("upgrades and migrated preferences do not trigger first-run onboarding", arguments: [true, false])
    func skipsExistingUsers(launchMarker: Bool) throws {
        let name = "NotchMenuHintTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        if !launchMarker { defaults.set(false, forKey: "border.enabled") }
        let existing = launchMarker || NotchMenuHintEligibility.hasExistingPreferences(
            in: defaults.persistentDomain(forName: name) ?? [:]
        )
        #expect(!NotchMenuHintEligibility(defaults: defaults, hasUsedAppBefore: existing).shouldOffer)
    }

    @Test("model initializes onboarding before default registration and appearance reset preserves completion")
    func modelIntegration() throws {
        let name = "NotchMenuHintTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = BorderModel(defaults: defaults, startIntegration: false, startOverlay: false)
        #expect(defaults.object(forKey: NotchMenuHintEligibility.completionKey) != nil)
        #expect(!defaults.bool(forKey: NotchMenuHintEligibility.completionKey))
        defaults.set(true, forKey: NotchMenuHintEligibility.completionKey)
        model.resetAppearance()
        #expect(defaults.bool(forKey: NotchMenuHintEligibility.completionKey))
    }
}
