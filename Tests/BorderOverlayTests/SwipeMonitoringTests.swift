import Testing
@testable import BorderOverlay

struct SwipeMonitoringTests {
    @Test("only horizontal DockControl swipe phases are accepted")
    func parserAcceptsMetadataSignature() {
        let began = SwipeGestureEventParser.classify(
            eventType: 30, eventTypeField: 30, hidType: 23, motion: 1, phase: 1)
        let changed = SwipeGestureEventParser.classify(
            eventType: 30, eventTypeField: 30, hidType: 23, motion: 1, phase: 2)
        let ended = SwipeGestureEventParser.classify(
            eventType: 30, eventTypeField: 30, hidType: 23, motion: 1, phase: 4)
        let cancelled = SwipeGestureEventParser.classify(
            eventType: 30, eventTypeField: 30, hidType: 23, motion: 1, phase: 8)

        #expect(began == .began)
        #expect(changed == .changed)
        #expect(ended == .ended)
        #expect(cancelled == .cancelled)
    }

    @Test("vertical, ordinary, and malformed events are ignored")
    func parserRejectsNonGestureEvents() {
        let cases: [(UInt32, Int64, Int64, Int64, Int64)] = [
            (1, 30, 23, 1, 1),       // ordinary mouse event
            (30, 29, 23, 1, 1),      // wrong embedded event type
            (30, 30, 22, 1, 1),      // another HID source
            (30, 30, 23, -1, 1),     // vertical motion
            (30, 30, 23, 1, 0),      // no phase bit
            (30, 30, 23, 1, -1)      // malformed phase
        ]
        for values in cases {
            #expect(SwipeGestureEventParser.classify(
                eventType: values.0, eventTypeField: values.1, hidType: values.2,
                motion: values.3, phase: values.4) == nil)
        }
    }

    @MainActor
    @Test("a held swipe stays hidden beyond the normal Space fallback deadline")
    func heldGestureOwnsTransition() async throws {
        let coordinator = SpaceTransitionCoordinator(
            hiddenDelay: 0.01, revealDuration: 0.01, gestureWatchdog: 0.25,
            gestureSettle: 0.01, postGestureSuppression: 0.05)
        coordinator.beginGesture()
        try await Task.sleep(for: .milliseconds(70))
        coordinator.beginFallback()
        #expect(coordinator.phase == .hidden)
        try await Task.sleep(for: .milliseconds(70))
        #expect(coordinator.phase == .hidden)
        coordinator.endGesture()
        try await waitUntil(coordinator, reaches: .idle)
    }

    @MainActor
    @Test("terminal swipe settles, then suppresses the delayed Space notification")
    func terminalAndFallbackCoalesce() async throws {
        let coordinator = SpaceTransitionCoordinator(
            hiddenDelay: 0.01, revealDuration: 0.02, gestureWatchdog: 1,
            gestureSettle: 0.04, postGestureSuppression: 0.12)
        var phases: [SpaceTransitionCoordinator.Phase] = []
        coordinator.onPhaseChange = { phases.append($0) }
        coordinator.beginGesture()
        coordinator.endGesture()
        try await Task.sleep(for: .milliseconds(15))
        #expect(coordinator.phase == .hidden)
        coordinator.beginFallback()
        try await waitUntil(coordinator, reaches: .idle)
        #expect(phases == [.hidden, .revealing, .idle])
        coordinator.beginFallback()
        #expect(coordinator.phase == .idle)
    }

    @MainActor
    @Test("missing terminal event recovers after the conservative watchdog")
    func missingEndRecovers() async throws {
        let coordinator = SpaceTransitionCoordinator(
            hiddenDelay: 0.01, revealDuration: 0.01, gestureWatchdog: 0.04,
            gestureSettle: 0.01, postGestureSuppression: 0.01)
        var timedOut = false
        coordinator.onGestureTimeout = { timedOut = true }
        coordinator.beginGesture()
        try await waitUntil(coordinator, reaches: .idle, limit: 30)
        #expect(timedOut)
        coordinator.cancel()
    }

    @MainActor
    private func waitUntil(
        _ coordinator: SpaceTransitionCoordinator,
        reaches expected: SpaceTransitionCoordinator.Phase,
        limit: Int = 100
    ) async throws {
        for _ in 0..<limit {
            if coordinator.phase == expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(coordinator.phase == expected)
    }
}
