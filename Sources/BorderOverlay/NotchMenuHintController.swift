import AppKit
import SwiftUI

/// A finite, nonactivating introduction. No polling or animation survives dismissal.
@MainActor
final class NotchMenuHintController {
    struct Target: Equatable {
        let notch: CGRect
        let screen: CGRect
    }

    private var offered = false
    private var completed = false
    private var target: Target?
    private var onComplete: (() -> Void)?
    private var presentationTask: Task<Void, Never>?
    private var dismissalTask: Task<Void, Never>?
    private(set) var panel: NSPanel?
    private let delay: Duration
    private let duration: Duration

    init(delay: Duration = .seconds(1.5), duration: Duration = .seconds(12)) {
        self.delay = delay
        self.duration = duration
    }

    func offer(onComplete: @escaping () -> Void) {
        guard !offered else { return }
        offered = true
        self.onComplete = onComplete
    }

    func reconcile(target: Target?) {
        self.target = target
        guard offered else { return }
        guard let target else {
            dismiss()
            return
        }
        if let panel {
            panel.setFrameOrigin(Self.origin(for: panel.frame.size, target: target))
            return
        }
        guard !completed, presentationTask == nil else { return }
        presentationTask = Task { [weak self, delay] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.presentationTask = nil
            self.present()
        }
    }

    /// Opening the menu before the delay expires also completes discovery.
    func menuOpened() {
        if offered { complete() }
        dismiss()
    }

    func dismiss() {
        presentationTask?.cancel()
        presentationTask = nil
        dismissalTask?.cancel()
        dismissalTask = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    func stop() {
        dismiss()
        target = nil
        offered = false
        onComplete = nil
    }

    private func present() {
        guard offered, !completed, let target else { return }
        let view = NSHostingView(rootView: NotchMenuHintView { [weak self] in self?.dismiss() })
        let size = view.fittingSize
        let frame = CGRect(origin: Self.origin(for: size, target: target), size: size)
        let panel = OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.contentView = view
        self.panel = panel
        panel.orderFrontRegardless()
        complete()
        NSAccessibility.post(element: view, notification: .announcementRequested, userInfo: [
            .announcement: "Click your camera notch to open the Notchlight menu.",
            .priority: NSAccessibilityPriorityLevel.medium.rawValue
        ])
        dismissalTask = Task { [weak self, duration] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func complete() {
        guard !completed else { return }
        completed = true
        onComplete?()
        onComplete = nil
    }

    static func origin(for size: CGSize, target: Target) -> CGPoint {
        CGPoint(
            x: min(max(target.notch.midX - size.width / 2, target.screen.minX + 8),
                   target.screen.maxX - size.width - 8),
            y: target.notch.minY - size.height - 6
        )
    }

    isolated deinit {
        presentationTask?.cancel()
        dismissalTask?.cancel()
        panel?.orderOut(nil)
    }
}
