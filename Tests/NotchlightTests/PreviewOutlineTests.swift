import AppKit
import SwiftUI
import Testing
@testable import Notchlight

@MainActor
struct PreviewOutlineTests {
    @Test("pulse preserves its curve and does not restart for an appearance update")
    func animationLifecycle() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 156, height: 34),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = PreviewOutlineView()
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        var style = PreviewOutlineView.Style(color: .blue, lineWidth: 3, outset: 2,
            start: 0.2, end: 0.8, isEnabled: true, glow: true, shouldPulse: true)
        view.update(style)
        let animation = try #require(view.strokeLayer.animation(forKey: PreviewOutlineView.pulseKey) as? CAAnimationGroup)
        #expect(animation.duration == 1.8)
        let opacity = try #require(animation.animations?.first as? CAKeyframeAnimation)
        let values = try #require(opacity.values as? [Double])
        #expect(values.count == 61)
        #expect(abs(values[0] - 0.25) < 0.0001)
        #expect(abs(values[30] - 1) < 0.0001)
        #expect(abs(values[60] - 0.25) < 0.0001)
        style.color = .red
        view.update(style)
        #expect(view.strokeLayer.animationKeys() == [PreviewOutlineView.pulseKey])
        #expect(view.strokeLayer.animation(forKey: PreviewOutlineView.pulseKey)?.beginTime == animation.beginTime)
        // Visibility and Reduce Motion arrive through the same shouldPulse input.
        style.shouldPulse = false
        view.update(style)
        #expect(view.strokeLayer.animationKeys()?.isEmpty != false)
        #expect(view.strokeLayer.shadowOpacity == 0.85)
        style.shouldPulse = true
        view.update(style)
        #expect(view.strokeLayer.animation(forKey: PreviewOutlineView.pulseKey) != nil)
        window.contentView = nil
        #expect(view.strokeLayer.animation(forKey: PreviewOutlineView.pulseKey) == nil)
    }

    @Test("trimmed stroke and shadow track geometry, disabled glow, and empty ranges")
    func geometryAndVisibility() throws {
        let view = PreviewOutlineView()
        view.frame = CGRect(x: 0, y: 0, width: 156, height: 34)
        var style = PreviewOutlineView.Style(color: .blue, lineWidth: 4, outset: 3,
            start: 0.1, end: 0.6, isEnabled: true, glow: true, shouldPulse: false)
        view.update(style)
        let path = PreviewNotchShape(outset: 3).path(in: view.bounds).trimmedPath(from: 0.1, to: 0.6).cgPath
        #expect(view.strokeLayer.path == path)
        #expect(view.strokeLayer.shadowPath == path.copy(strokingWithWidth: 4, lineCap: .round, lineJoin: .round, miterLimit: 10))
        view.frame.size.width = 220
        view.layout()
        #expect(view.strokeLayer.path != path)
        style.glow = false; view.update(style)
        #expect(view.strokeLayer.shadowOpacity == 0)
        style.end = style.start; view.update(style)
        #expect(view.strokeLayer.isHidden)
        #expect(view.strokeLayer.shadowPath == nil)
        style.end = 1; style.isEnabled = false; view.update(style)
        #expect(view.strokeLayer.isHidden)
        #expect(view.hitTest(.zero) == nil)
    }
}
