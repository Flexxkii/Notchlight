import Observation

/// Window visibility is independent of focus: a visible inactive window can still animate.
@MainActor
@Observable
final class SettingsWindowState {
    private(set) var canAnimate = false
    @ObservationIgnored private var revision = 0

    /// Prevent a deferred reset from a dismantled observer overwriting its replacement.
    func reserveUpdate() -> Int {
        revision &+= 1
        return revision
    }

    func isCurrent(_ update: Int) -> Bool { update == revision }

    func update(isVisible: Bool, isMiniaturized: Bool, isOccluded: Bool) {
        revision &+= 1
        canAnimate = isVisible && !isMiniaturized && !isOccluded
    }
}
