import AppKit
import Testing
@testable import BorderOverlay

@MainActor
struct NotchMenuHintTests {
    private let target = NotchMenuHintController.Target(
        notch: CGRect(x: -840, y: 950, width: 180, height: 32),
        screen: CGRect(x: -1512, y: 0, width: 1512, height: 982)
    )

    @Test("a missing display and a cancelled launch delay do not consume the hint")
    func cancelledPresentation() async throws {
        let controller = NotchMenuHintController(delay: .milliseconds(25))
        var completions = 0
        controller.offer { completions += 1 }
        controller.reconcile(target: nil)
        controller.reconcile(target: target)
        controller.reconcile(target: nil)
        try await Task.sleep(for: .milliseconds(60))
        #expect(completions == 0)
        #expect(controller.panel == nil)
        controller.stop()
    }

    @Test("opening the menu cancels a pending hint and completes discovery only once")
    func menuWins() async throws {
        let controller = NotchMenuHintController(delay: .milliseconds(25))
        var completions = 0
        controller.offer { completions += 1 }
        controller.reconcile(target: target)
        controller.menuOpened()
        controller.menuOpened()
        controller.reconcile(target: target)
        try await Task.sleep(for: .milliseconds(60))
        #expect(completions == 1)
        #expect(controller.panel == nil)
        controller.stop()
    }

    @Test("stopping services cancels pending onboarding without consuming it")
    func stopCancels() async throws {
        let controller = NotchMenuHintController(delay: .milliseconds(25))
        var completed = false
        controller.offer { completed = true }
        controller.reconcile(target: target)
        controller.stop()
        try await Task.sleep(for: .milliseconds(60))
        #expect(!completed)
        #expect(controller.panel == nil)
    }

    @Test("hint placement follows physical notch coordinates on an offset display")
    func placement() {
        let size = CGSize(width: 280, height: 110)
        let origin = NotchMenuHintController.origin(for: size, target: target)
        #expect(origin.x + size.width / 2 == target.notch.midX)
        #expect(origin.y + size.height < target.notch.minY)
        #expect(origin.x >= target.screen.minX)
        #expect(origin.x + size.width <= target.screen.maxX)
    }
}
