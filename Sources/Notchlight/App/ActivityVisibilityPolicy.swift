import Foundation

struct ActivityVisibilityPolicy {
    static func isVisible(masterEnabled: Bool, filterEnabled: Bool, linked: Bool,
                          available: Bool, working: Bool, idleSince: Date?, now: Date,
                          timeoutMinutes: Double) -> Bool {
        guard masterEnabled else { return false }
        guard filterEnabled else { return true }
        guard linked else { return false }
        if available && working { return true }
        guard let idleSince else { return false }
        return now.timeIntervalSince(idleSince) < max(0, timeoutMinutes) * 60
    }
}
