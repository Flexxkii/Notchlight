import AppKit
import Diagnostics
import Testing
@testable import Notchlight

@MainActor
struct SettingsWindowStateTests {
    @Test("preview follows its own window through visibility, minimization, and occlusion")
    func lifecycle() async throws {
        _ = NSApplication.shared
        let state = SettingsWindowState()
        let window = SimulatedSettingsWindow()
        let view = SettingsWindowObserverView(recorder: .disabled, state: state)
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        #expect(!state.canAnimate)

        window.simulatedVisible = true
        window.simulatedOcclusion = [.visible]
        notify(NSWindow.didChangeOcclusionStateNotification, window)
        try await settle()
        #expect(state.canAnimate)

        // Losing focus must not pause a window that remains visible.
        notify(NSWindow.didResignKeyNotification, window)
        try await settle()
        #expect(state.canAnimate)

        window.simulatedOcclusion = []
        notify(NSWindow.didChangeOcclusionStateNotification, window)
        try await settle()
        #expect(!state.canAnimate)

        window.simulatedOcclusion = [.visible]
        window.simulatedMinimized = true
        notify(NSWindow.didMiniaturizeNotification, window)
        try await settle()
        #expect(!state.canAnimate)

        window.simulatedMinimized = false
        notify(NSWindow.didDeminiaturizeNotification, window)
        try await settle()
        #expect(state.canAnimate)

        // willClose arrives before AppKit updates isVisible.
        notify(NSWindow.willCloseNotification, window)
        try await settle()
        #expect(!state.canAnimate)
        notify(NSWindow.didBecomeKeyNotification, window)
        try await settle()
        #expect(state.canAnimate)

        window.simulatedVisible = false
        notify(NSWindow.didChangeOcclusionStateNotification, window)
        try await settle()
        #expect(!state.canAnimate)
    }

    @Test("moving the observer removes old-window callbacks and detachment pauses")
    func moveAndDetach() async throws {
        _ = NSApplication.shared
        let state = SettingsWindowState()
        let first = SimulatedSettingsWindow()
        let second = SimulatedSettingsWindow()
        var view: SettingsWindowObserverView? = SettingsWindowObserverView(recorder: .disabled, state: state)
        weak var releasedView: SettingsWindowObserverView?
        releasedView = view
        first.contentView = view
        first.simulatedVisible = true
        first.simulatedOcclusion = [.visible]
        notify(NSWindow.didChangeOcclusionStateNotification, first)
        try await settle()
        #expect(state.canAnimate)

        first.contentView = nil
        second.contentView = view
        try await settle()
        #expect(!state.canAnimate)
        notify(NSWindow.didBecomeKeyNotification, first)
        try await settle()
        #expect(!state.canAnimate)

        second.simulatedVisible = true
        second.simulatedOcclusion = [.visible]
        notify(NSWindow.didChangeOcclusionStateNotification, second)
        try await settle()
        #expect(state.canAnimate)
        view?.stopObserving()
        try await settle()
        #expect(!state.canAnimate)
        notify(NSWindow.didBecomeKeyNotification, second)
        try await settle()
        #expect(!state.canAnimate)
        second.contentView = nil
        view = nil
        try await settle()
        #expect(releasedView == nil)
        first.close(); second.close()
    }

    @Test("preview pulse retains its 1.8 second period and zero-to-one range")
    func pulsePeriod() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        #expect(BorderPreviewOutline.pulseAmount(at: start) == 0)
        #expect(abs(BorderPreviewOutline.pulseAmount(at: start.addingTimeInterval(0.9)) - 1) < 0.0001)
        #expect(abs(BorderPreviewOutline.pulseAmount(at: start.addingTimeInterval(1.8))) < 0.0001)
    }

    @Test("an immediately released observer resets visibility without overwriting its replacement")
    func immediateTeardown() async throws {
        _ = NSApplication.shared
        let state = SettingsWindowState()
        let window = SimulatedSettingsWindow()
        window.simulatedVisible = true
        window.simulatedOcclusion = [.visible]
        var view: SettingsWindowObserverView? = SettingsWindowObserverView(recorder: .disabled, state: state)
        window.contentView = view
        try await settle()
        #expect(state.canAnimate)
        window.contentView = nil
        view = nil
        try await settle()
        #expect(!state.canAnimate)

        view = SettingsWindowObserverView(recorder: .disabled, state: state)
        window.contentView = view
        try await settle()
        #expect(state.canAnimate)
        window.contentView = nil
        view = nil
        // Install a replacement before the old observer's deferred reset runs.
        let replacement = SettingsWindowObserverView(recorder: .disabled, state: state)
        window.contentView = replacement
        replacement.recordState()
        try await settle()
        #expect(state.canAnimate)
        window.contentView = nil
        window.close()
    }

    private func notify(_ name: Notification.Name, _ window: NSWindow) {
        NotificationCenter.default.post(name: name, object: window)
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor
private final class SimulatedSettingsWindow: NSWindow {
    var simulatedVisible = false
    var simulatedMinimized = false
    var simulatedOcclusion: NSWindow.OcclusionState = []
    override var isVisible: Bool { simulatedVisible }
    override var isMiniaturized: Bool { simulatedMinimized }
    override var occlusionState: NSWindow.OcclusionState { simulatedOcclusion }

    init() {
        super.init(contentRect: .init(x: 0, y: 0, width: 200, height: 100),
                   styleMask: [.titled], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
    }
}
