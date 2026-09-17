import Foundation

/// Initialized before registering defaults, so an upgrade is not a fresh install.
@MainActor
final class NotchMenuHintEligibility {
    static let completionKey = "onboarding.notchMenuHintShown"
    private let defaults: UserDefaults

    var shouldOffer: Bool { !defaults.bool(forKey: Self.completionKey) }

    init(defaults: UserDefaults, hasUsedAppBefore: Bool) {
        self.defaults = defaults
        if defaults.object(forKey: Self.completionKey) == nil {
            defaults.set(hasUsedAppBefore, forKey: Self.completionKey)
        }
    }

    static func hasExistingPreferences(in persisted: [String: Any]) -> Bool {
        persisted.keys.contains {
            $0.hasPrefix("border.") || $0.hasPrefix("codex.") || $0.hasPrefix("strips.")
        }
    }

    func complete() {
        defaults.set(true, forKey: Self.completionKey)
    }
}
