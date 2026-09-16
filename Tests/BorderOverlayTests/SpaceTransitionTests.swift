import AppKit
import Testing

@testable import BorderOverlay

struct SpaceTransitionTests {
    @MainActor
    @Test("Space transition coordinator reveals after its conceal delay")
    func coordinatorLifecycle() async throws {
        let coordinator = SpaceTransitionCoordinator(hiddenDelay: 0.02, revealDuration: 0.02)
        var phases: [SpaceTransitionCoordinator.Phase] = []
        coordinator.onPhaseChange = { phases.append($0) }

        coordinator.begin()
        #expect(coordinator.phase == .hidden)
        try await waitUntil(coordinator, reaches: .revealing)
        #expect(coordinator.phase == .revealing)
        try await waitUntil(coordinator, reaches: .idle)
        #expect(coordinator.phase == .idle)
        #expect(phases == [.hidden, .revealing, .idle])
    }

    @MainActor
    @Test("repeated begins coalesce and keep the overlay hidden")
    func repeatedBeginsResetTheGeneration() async throws {
        let coordinator = SpaceTransitionCoordinator(hiddenDelay: 0.05, revealDuration: 0.01)
        var phases: [SpaceTransitionCoordinator.Phase] = []
        coordinator.onPhaseChange = { phases.append($0) }

        coordinator.begin()
        try await Task.sleep(for: .milliseconds(20))
        coordinator.begin()
        #expect(coordinator.phase == .hidden)
        try await waitUntil(coordinator, reaches: .revealing)
        try await waitUntil(coordinator, reaches: .idle)
        #expect(coordinator.phase == .idle)
        #expect(phases == [.hidden, .revealing, .idle])
    }

    @MainActor
    @Test("cancel returns to idle and prevents delayed callbacks")
    func coordinatorCancellation() async throws {
        let coordinator = SpaceTransitionCoordinator(hiddenDelay: 0.05, revealDuration: 0.01)
        var phases: [SpaceTransitionCoordinator.Phase] = []
        coordinator.onPhaseChange = { phases.append($0) }

        coordinator.begin()
        coordinator.cancel()
        #expect(coordinator.phase == .idle)
        try await Task.sleep(for: .milliseconds(80))
        #expect(coordinator.phase == .idle)
        #expect(phases == [.hidden, .idle])
    }

    @MainActor
    @Test("coordinator does not retain itself through a pending transition")
    func coordinatorDeallocatesWithPendingTask() async throws {
        weak var weakCoordinator: SpaceTransitionCoordinator?
        do {
            let coordinator = SpaceTransitionCoordinator(hiddenDelay: 0.2, revealDuration: 0.2)
            weakCoordinator = coordinator
            coordinator.begin()
        }
        #expect(weakCoordinator == nil)
        try await Task.sleep(for: .milliseconds(20))
        #expect(weakCoordinator == nil)
    }

    @MainActor
    @Test("space concealment animates the root without disturbing pulse")
    func rootTransitionPreservesChildAnimations() throws {
        let view = makeView(glow: true, pulse: true, reduceMotion: false)
        let root = try #require(view.layer)
        let border = try #require(root.sublayers?.compactMap { $0 as? CAShapeLayer }.first(where: { $0.name == "border" }))
        #expect(border.animation(forKey: "borderPulseOpacity") != nil)

        view.setSpaceTransitionHidden(true, animated: true)
        #expect(root.opacity == 0)
        #expect(root.transform.m42 == 12)
        let opacity = try #require(root.animation(forKey: "spaceTransitionOpacity") as? CABasicAnimation)
        let translation = try #require(root.animation(forKey: "spaceTransitionTranslation") as? CABasicAnimation)
        #expect(opacity.keyPath == "opacity")
        #expect(opacity.duration == 0.14)
        #expect(translation.keyPath == "transform.translation.y")
        #expect(translation.duration == 0.14)
        #expect(border.animation(forKey: "borderPulseOpacity") != nil)

        // Routine appearance updates leave the root transition animation in place.
        view.updateAppearance(
            lineWidth: 2,
            glow: true,
            pulse: true,
            padding: 0,
            strokeRange: .init(start: 0, end: 1),
            color: .systemRed,
            strips: BorderStripStyle(isEnabled: false),
            reduceMotion: false,
            content: NotchHoverContent(),
            isEnabled: true
        )
        #expect(root.animation(forKey: "spaceTransitionOpacity") != nil)
        #expect(border.animation(forKey: "borderPulseOpacity") != nil)
    }

    @MainActor
    @Test("reveal reverses from the current root presentation and reduce motion fades only")
    func rootReversalAndReduceMotion() throws {
        let view = makeView(glow: false, pulse: false, reduceMotion: false)
        let root = try #require(view.layer)
        view.setSpaceTransitionHidden(true, animated: true)
        view.setSpaceTransitionHidden(false, animated: true)
        let revealOpacity = try #require(root.animation(forKey: "spaceTransitionOpacity") as? CABasicAnimation)
        let revealTranslation = try #require(root.animation(forKey: "spaceTransitionTranslation") as? CABasicAnimation)
        #expect(revealOpacity.fromValue != nil)
        #expect(revealOpacity.toValue != nil)
        #expect(revealTranslation.fromValue != nil)
        #expect(revealTranslation.toValue != nil)
        #expect(revealOpacity.duration == 0.28)
        #expect(revealTranslation.duration == 0.28)

        let reduced = makeView(glow: false, pulse: false, reduceMotion: true)
        let reducedRoot = try #require(reduced.layer)
        reduced.setSpaceTransitionHidden(true, animated: true)
        #expect(reducedRoot.opacity == 0)
        #expect(reducedRoot.transform.m42 == 0)
        #expect(reducedRoot.animation(forKey: "spaceTransitionOpacity") != nil)
        #expect(reducedRoot.animation(forKey: "spaceTransitionTranslation") == nil)
    }

    @MainActor
    private func makeView(glow: Bool, pulse: Bool, reduceMotion: Bool) -> OverlayView {
        OverlayView(
            frame: CGRect(x: 0, y: 900, width: 700, height: 82),
            drawing: .physical(PhysicalBorderGeometry(
                screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                notch: NotchGeometry(rect: CGRect(x: 663.5, y: 950, width: 185, height: 32)),
                leftX: 661,
                rightX: 851,
                topY: 982,
                bottomY: 948,
                cornerRadius: 8
            )),
            lineWidth: 2,
            glow: glow,
            pulse: pulse,
            padding: 0,
            strokeRange: .init(start: 0, end: 1),
            color: .systemRed,
            strips: BorderStripStyle(isEnabled: false),
            reduceMotion: reduceMotion,
            globalOrigin: .zero,
            content: NotchHoverContent(usageText: "42%", resetText: "1h"),
            isEnabled: true
        )
    }

    @MainActor
    private func waitUntil(
        _ coordinator: SpaceTransitionCoordinator,
        reaches expected: SpaceTransitionCoordinator.Phase
    ) async throws {
        for _ in 0..<100 {
            if coordinator.phase == expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(coordinator.phase == expected)
    }
}
