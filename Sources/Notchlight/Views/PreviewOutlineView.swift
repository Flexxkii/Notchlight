import SwiftUI

@MainActor
final class PreviewOutlineView: NSView {
    struct Style: Equatable {
        var color: NSColor
        var lineWidth: CGFloat
        var outset: CGFloat
        var start: CGFloat
        var end: CGFloat
        var isEnabled: Bool
        var glow: Bool
        var shouldPulse: Bool
    }

    private(set) var style: Style?
    let strokeLayer = CAShapeLayer()
    static let pulseKey = "previewPulse"

    init() {
        super.init(frame: .zero)
        clipsToBounds = false
        wantsLayer = true
        layer?.masksToBounds = false
        strokeLayer.fillColor = nil
        strokeLayer.lineCap = .round
        strokeLayer.shadowOffset = .zero
        layer?.addSublayer(strokeLayer)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(_ style: Style) {
        guard self.style != style else { return }
        self.style = style
        render()
    }

    override func layout() {
        super.layout()
        render()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        render()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        render()
    }

    private func render() {
        guard let style else { return }
        let start = min(1, max(0, style.start)), end = min(1, max(0, style.end))
        let visible = style.isEnabled && end > start && style.lineWidth > 0 && !bounds.isEmpty
        let pulse = visible && style.glow && style.shouldPulse && window != nil
        let path = PreviewNotchShape(outset: style.outset).path(in: bounds)
            .trimmedPath(from: start, to: max(start, end)).cgPath

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strokeLayer.frame = bounds
        strokeLayer.contentsScale = window?.backingScaleFactor ?? 2
        strokeLayer.path = path
        strokeLayer.strokeColor = style.color.cgColor
        strokeLayer.lineWidth = style.lineWidth
        strokeLayer.isHidden = !visible
        strokeLayer.shadowColor = style.color.cgColor
        // The shadow follows the trimmed stroke, including its rounded endpoints.
        // Its geometry only changes with appearance or layout, never per frame.
        strokeLayer.shadowPath = visible ? path.copy(strokingWithWidth: style.lineWidth,
            lineCap: .round, lineJoin: .round, miterLimit: 10) : nil
        strokeLayer.shadowOpacity = style.glow && visible ? (pulse ? 0.25 : 0.85) : 0
        strokeLayer.shadowRadius = pulse ? 3 : 8
        CATransaction.commit()

        if pulse {
            if strokeLayer.animation(forKey: Self.pulseKey) == nil { startAnimating() }
        } else { stopAnimating() }
    }

    private func startAnimating() {
        // Sample the original sine curve once, then interpolate in the compositor.
        let values = (0...60).map { BorderPreviewOutline.pulseAmount(at:
            Date(timeIntervalSinceReferenceDate: Double($0) / 60 * 1.8)) }
        let opacity = CAKeyframeAnimation(keyPath: "shadowOpacity")
        opacity.values = values.map { 0.25 + 0.75 * $0 }
        opacity.duration = 1.8
        let radius = CAKeyframeAnimation(keyPath: "shadowRadius")
        radius.values = values.map { 3 + 9 * $0 }
        radius.duration = 1.8
        let group = CAAnimationGroup()
        group.animations = [opacity, radius]
        group.duration = 1.8
        group.repeatCount = .infinity
        let now = CACurrentMediaTime()
        group.beginTime = strokeLayer.convertTime(now, from: nil)
            - Date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8)
        strokeLayer.add(group, forKey: Self.pulseKey)
    }

    func stopAnimating() { strokeLayer.removeAnimation(forKey: Self.pulseKey) }
}
