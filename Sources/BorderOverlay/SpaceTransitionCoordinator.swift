import Foundation

/// Coordinates the short conceal/reveal window around an active-Space change.
/// It deliberately has no dependency on the display or window controller: the
/// owner decides how to apply each phase to its panels.
@MainActor
final class SpaceTransitionCoordinator {
    enum Phase: Equatable, Sendable {
        case idle
        case hidden
        case revealing
    }

    private(set) var phase: Phase = .idle
    var onPhaseChange: ((Phase) -> Void)?

    private let hiddenDelayNanoseconds: UInt64
    private let revealDurationNanoseconds: UInt64
    // A terminal Dock event can be lost while the app is paused. Ten seconds
    // bounds how long that ambiguity can hide the border without interrupting
    // a normal, deliberately held swipe.
    private let gestureWatchdogNanoseconds: UInt64
    private let gestureSettleNanoseconds: UInt64
    private let postGestureSuppressionNanoseconds: UInt64
    private var generation: UInt64 = 0
    private var pendingTask: Task<Void, Never>?
    private var gestureWatchdogTask: Task<Void, Never>?
    private var postGestureSuppressionTask: Task<Void, Never>?
    private var gestureHeld = false
    private var suppressingFallback = false
    var onGestureTimeout: (() -> Void)?

    init(hiddenDelay: TimeInterval = 0.35, revealDuration: TimeInterval = 0.28,
         gestureWatchdog: TimeInterval = 10, gestureSettle: TimeInterval = 0.22,
         postGestureSuppression: TimeInterval = 0.45) {
        hiddenDelayNanoseconds = Self.nanoseconds(for: hiddenDelay)
        revealDurationNanoseconds = Self.nanoseconds(for: revealDuration)
        gestureWatchdogNanoseconds = Self.nanoseconds(for: gestureWatchdog)
        gestureSettleNanoseconds = Self.nanoseconds(for: gestureSettle)
        postGestureSuppressionNanoseconds = Self.nanoseconds(for: postGestureSuppression)
    }

    func begin() {
        guard !gestureHeld, !suppressingFallback else { return }
        generation &+= 1
        let token = generation
        let hiddenDelay = hiddenDelayNanoseconds
        let revealDuration = revealDurationNanoseconds
        pendingTask?.cancel()
        pendingTask = nil
        setPhase(.hidden)

        pendingTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: hiddenDelay) }
            catch { return }
            guard !Task.isCancelled else { return }
            do {
                guard let self, self.generation == token else { return }
                self.setPhase(.revealing)
            }
            do { try await Task.sleep(nanoseconds: revealDuration) }
            catch { return }
            guard !Task.isCancelled else { return }
            guard let self, self.generation == token else { return }
            self.setPhase(.idle)
            self.pendingTask = nil
        }
    }

    /// Holds the overlay concealed for the duration of a real trackpad swipe.
    /// Unlike begin(), this has no short auto-reveal delay.
    func beginGesture() {
        generation &+= 1
        let token = generation
        pendingTask?.cancel()
        pendingTask = nil
        postGestureSuppressionTask?.cancel()
        postGestureSuppressionTask = nil
        suppressingFallback = false
        gestureHeld = true
        setPhase(.hidden)
        scheduleGestureWatchdog(token: token)
    }

    func noteGestureChange() {
        guard gestureHeld else { return }
        scheduleGestureWatchdog(token: generation)
    }

    func endGesture() {
        guard gestureHeld else { return }
        gestureHeld = false
        gestureWatchdogTask?.cancel()
        gestureWatchdogTask = nil
        generation &+= 1
        // Dock can send the terminal event slightly before it finishes moving
        // the desktop. Keep the notch concealed during this short settle.
        suppressingFallback = true
        finishGestureReveal()
    }

    /// Handles the normal active-space notification. A held gesture owns the
    /// conceal period, and an in-flight reveal is left alone to avoid a second
    /// fade when Dock posts its delayed notification.
    func beginFallback() {
        begin()
    }

    func cancel() {
        generation &+= 1
        pendingTask?.cancel()
        pendingTask = nil
        gestureWatchdogTask?.cancel()
        gestureWatchdogTask = nil
        postGestureSuppressionTask?.cancel()
        postGestureSuppressionTask = nil
        suppressingFallback = false
        gestureHeld = false
        setPhase(.idle)
    }

    isolated deinit {
        pendingTask?.cancel()
        gestureWatchdogTask?.cancel()
        postGestureSuppressionTask?.cancel()
    }

    private func setPhase(_ next: Phase) {
        guard phase != next else { return }
        phase = next
        onPhaseChange?(next)
    }

    private func scheduleGestureWatchdog(token: UInt64) {
        gestureWatchdogTask?.cancel()
        let timeout = gestureWatchdogNanoseconds
        gestureWatchdogTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: timeout) }
            catch { return }
            guard !Task.isCancelled else { return }
            guard let self, self.generation == token, self.gestureHeld else { return }
            self.gestureHeld = false
            self.gestureWatchdogTask = nil
            self.onGestureTimeout?()
            self.finishGestureReveal()
        }
    }

    private func finishGestureReveal() {
        generation &+= 1
        let token = generation
        suppressingFallback = true
        setPhase(.hidden)
        let settle = gestureSettleNanoseconds
        let duration = revealDurationNanoseconds
        pendingTask?.cancel()
        pendingTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: settle) }
            catch { return }
            guard !Task.isCancelled else { return }
            do {
                guard let self, self.generation == token, !self.gestureHeld else { return }
                self.setPhase(.revealing)
            }
            do { try await Task.sleep(nanoseconds: duration) }
            catch { return }
            guard !Task.isCancelled else { return }
            do {
                guard let self, self.generation == token, !self.gestureHeld else { return }
                self.setPhase(.idle)
                self.pendingTask = nil
                self.startFallbackSuppression()
            }
        }
    }

    private func startFallbackSuppression() {
        suppressingFallback = true
        postGestureSuppressionTask?.cancel()
        let duration = postGestureSuppressionNanoseconds
        postGestureSuppressionTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: duration) }
            catch { return }
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.suppressingFallback = false
            self.postGestureSuppressionTask = nil
        }
    }

    private static func nanoseconds(for seconds: TimeInterval) -> UInt64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return UInt64(min(seconds * 1_000_000_000, Double(UInt64.max)))
    }
}
