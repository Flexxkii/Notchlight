import AppKit
import Diagnostics

final class OverlayView: NSView {
    enum Drawing: Equatable {
        case physical(PhysicalBorderGeometry)
    }

    var drawing: Drawing
    var lineWidth: CGFloat
    var glow: Bool
    var pulse: Bool
    var padding: CGFloat
    var strokeRange: OverlayGeometry.StrokeRange
    var color: NSColor
    var strips: BorderStripStyle
    private var content: NotchHoverContent
    private var hoverStyle: NotchHoverStyle
    private var isEnabled: Bool
    private var isExpanded = false

    /// Origin of the panel in global screen coordinates. Content views are
    /// laid out in panel-local coordinates, while geometry uses NSScreen's
    /// global coordinates.
    private var globalOrigin: CGPoint
    private let borderLayer = CAShapeLayer()
    private let stripLayer = CAShapeLayer()
    private let fillLayer = CAShapeLayer()
    private let usageContainer = CALayer()
    private let resetContainer = CALayer()
    private let usageTextLayer = CATextLayer()
    private let usageCaptionLayer = CATextLayer()
    private let resetTextLayer = CATextLayer()
    private let resetCaptionLayer = CATextLayer()
    private var reduceMotion: Bool
    private var hoverLayout: OverlayHoverLayout?
    private var renderGeneration = 0
    private var collapseTask: Task<Void, Never>?
    private var spaceTransitionHidden = false
    private let diagnostics: DiagnosticRecorder

    init(
        frame frameRect: NSRect,
        drawing: Drawing,
        lineWidth: CGFloat,
        glow: Bool,
        pulse: Bool,
        padding: CGFloat,
        strokeRange: OverlayGeometry.StrokeRange,
        color: NSColor,
        strips: BorderStripStyle,
        reduceMotion: Bool,
        globalOrigin: CGPoint,
        content: NotchHoverContent = NotchHoverContent(),
        hoverStyle: NotchHoverStyle = NotchHoverStyle(),
        isEnabled: Bool = true,
        diagnostics: DiagnosticRecorder = .disabled
    ) {
        self.drawing = drawing
        self.lineWidth = OverlayGeometry.normalizedLineWidth(lineWidth)
        self.glow = glow
        self.pulse = pulse
        self.padding = OverlayGeometry.normalizedPadding(padding)
        self.strokeRange = strokeRange
        self.color = color.usingColorSpace(.sRGB) ?? color
        self.strips = strips
        self.reduceMotion = reduceMotion
        self.globalOrigin = globalOrigin
        self.content = content
        self.hoverStyle = hoverStyle
        self.isEnabled = isEnabled
        self.diagnostics = diagnostics
        super.init(frame: frameRect)

        wantsLayer = true
        setAccessibilityElement(true)
        borderLayer.name = "border"
        stripLayer.name = "strips"
        fillLayer.name = "fill"
        usageContainer.name = "usage"
        resetContainer.name = "reset"
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false
        configureLayers()
    }

    convenience init(
        frame frameRect: NSRect,
        drawing: Drawing,
        lineWidth: CGFloat,
        glow: Bool,
        padding: CGFloat,
        strokeRange: OverlayGeometry.StrokeRange,
        color: NSColor,
        globalOrigin: CGPoint
    ) {
        self.init(
            frame: frameRect,
            drawing: drawing,
            lineWidth: lineWidth,
            glow: glow,
            pulse: false,
            padding: padding,
            strokeRange: strokeRange,
            color: color,
            strips: BorderStripStyle(),
            reduceMotion: false,
            globalOrigin: globalOrigin,
            content: NotchHoverContent(),
            isEnabled: true
        )
    }

    convenience init(
        frame frameRect: NSRect,
        drawing: Drawing,
        lineWidth: CGFloat,
        glow: Bool,
        padding: CGFloat,
        strokeRange: OverlayGeometry.StrokeRange,
        color: NSColor,
        strips: BorderStripStyle,
        globalOrigin: CGPoint
    ) {
        self.init(
            frame: frameRect,
            drawing: drawing,
            lineWidth: lineWidth,
            glow: glow,
            pulse: false,
            padding: padding,
            strokeRange: strokeRange,
            color: color,
            strips: strips,
            reduceMotion: false,
            globalOrigin: globalOrigin,
            content: NotchHoverContent(),
            isEnabled: true
        )
    }

    isolated deinit {
        collapseTask?.cancel()
    }

    required init?(coder: NSCoder) {
        fatalError("OverlayView does not support NSCoder initialization")
    }

    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var collapsedHitRect: CGRect {
        hoverLayout?.collapsedHitRect.offsetBy(dx: -globalOrigin.x, dy: -globalOrigin.y) ?? bounds
    }
    var expandedHitRect: CGRect {
        hoverLayout?.expandedHitRect.offsetBy(dx: -globalOrigin.x, dy: -globalOrigin.y) ?? bounds
    }
    var onClick: (() -> Void)?

    static func panelFrame(for geometry: PhysicalBorderGeometry, content: NotchHoverContent, margin: CGFloat, style: NotchHoverStyle = NotchHoverStyle()) -> NSRect {
        let layout = NotchHoverGeometry.layout(for: geometry, content: content, style: style)
        let rect = layout.expandedHitRect.insetBy(dx: -margin, dy: -margin)
        let screen = geometry.screenFrame.standardized
        let minX = max(screen.minX, rect.minX)
        let maxX = min(screen.maxX, rect.maxX)
        let minY = max(screen.minY, rect.minY)
        let maxY = min(screen.maxY, rect.maxY)
        return NSRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
    }

    func updateGeometry(_ geometry: PhysicalBorderGeometry, globalOrigin: CGPoint) {
        guard drawing != .physical(geometry) || self.globalOrigin != globalOrigin else { return }
        drawing = .physical(geometry)
        self.globalOrigin = globalOrigin
        render(expanded: isExpanded, animated: false, keepFillDuringCollapse: false)
    }

    func updateAppearance(
        lineWidth: CGFloat,
        glow: Bool,
        pulse: Bool,
        padding: CGFloat,
        strokeRange: OverlayGeometry.StrokeRange,
        color: NSColor,
        strips: BorderStripStyle,
        reduceMotion: Bool,
        content: NotchHoverContent,
        hoverStyle: NotchHoverStyle = NotchHoverStyle(),
        isEnabled: Bool
    ) {
        self.lineWidth = OverlayGeometry.normalizedLineWidth(lineWidth)
        self.glow = glow
        self.pulse = pulse
        self.padding = OverlayGeometry.normalizedPadding(padding)
        self.strokeRange = strokeRange
        self.color = color.usingColorSpace(.sRGB) ?? color
        self.strips = strips
        let reduceMotionChanged = self.reduceMotion != reduceMotion
        self.reduceMotion = reduceMotion
        self.content = content
        self.hoverStyle = hoverStyle
        self.isEnabled = isEnabled
        render(expanded: isExpanded, animated: false, keepFillDuringCollapse: false)
        if reduceMotionChanged {
            applySpaceTransition(animated: false)
        }
    }

    func setExpanded(_ expanded: Bool, animated: Bool = true) {
        guard isExpanded != expanded else { return }
        let wasExpanded = isExpanded
        isExpanded = expanded
        let shouldAnimate = animated && !reduceMotion
        render(expanded: expanded, animated: shouldAnimate, keepFillDuringCollapse: wasExpanded && !expanded && shouldAnimate)
    }

    /// Conceals the complete overlay while AppKit is moving between Spaces.
    /// The model state remains intact so a normal render/update can continue
    /// while the layer is faded out.
    func setSpaceTransitionHidden(_ hidden: Bool, animated: Bool = true) {
        guard spaceTransitionHidden != hidden else { return }
        spaceTransitionHidden = hidden
        applySpaceTransition(animated: animated)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .button
    }

    override func accessibilityLabel() -> String? {
        "Codex notch"
    }

    override func accessibilityValue() -> Any? {
        let usage = [content.usageText, content.usageCaption].filter { !$0.isEmpty }.joined(separator: " ")
        let reset = [content.resetText, content.resetCaption].filter { !$0.isEmpty }.joined(separator: " ")
        let value = [usage, reset].filter { !$0.isEmpty }.joined(separator: "; ")
        return value.isEmpty ? nil : value
    }

    private func configureLayers() {
        render(expanded: false, animated: false, keepFillDuringCollapse: false)
    }

    private func applySpaceTransition(animated: Bool) {
        guard let rootLayer = layer else { return }
        let targetOpacity: Float = spaceTransitionHidden ? 0 : 1
        let targetTranslation: CGFloat = spaceTransitionHidden && !reduceMotion ? 12 : 0
        let currentPresentation = rootLayer.presentation()
        let currentOpacity = currentPresentation?.opacity ?? rootLayer.opacity
        let currentTranslation = currentPresentation?.transform.m42 ?? rootLayer.transform.m42

        rootLayer.removeAnimation(forKey: "spaceTransitionOpacity")
        rootLayer.removeAnimation(forKey: "spaceTransitionTranslation")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.opacity = targetOpacity
        rootLayer.transform = CATransform3DMakeTranslation(0, targetTranslation, 0)
        if animated {
            let duration: CFTimeInterval = spaceTransitionHidden ? 0.14 : 0.28
            let timing = CAMediaTimingFunction(name: .easeInEaseOut)
            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = currentOpacity
            opacity.toValue = targetOpacity
            opacity.duration = duration
            opacity.timingFunction = timing
            rootLayer.add(opacity, forKey: "spaceTransitionOpacity")

            if !reduceMotion {
                let translation = CABasicAnimation(keyPath: "transform.translation.y")
                translation.fromValue = currentTranslation
                translation.toValue = targetTranslation
                translation.duration = duration
                translation.timingFunction = timing
                rootLayer.add(translation, forKey: "spaceTransitionTranslation")
            }
        }
        CATransaction.commit()
    }

    private func render(expanded: Bool, animated: Bool, keepFillDuringCollapse: Bool) {
        let measureDuration = diagnostics.isEnabled
        let startedAt = measureDuration ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if measureDuration {
                diagnostics.aggregate(.render,
                                      durationNanoseconds: DispatchTime.now().uptimeNanoseconds - startedAt)
            }
        }
        diagnostics.updateContext(["render.lastUpdateAnimated": .bool(animated)])
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard let rootLayer = layer else { return }
        let geometry: PhysicalBorderGeometry
        guard case let .physical(collapsed) = drawing else { return }
        let layout = NotchHoverGeometry.layout(for: collapsed, content: content, style: hoverStyle)
        hoverLayout = layout
        geometry = expanded ? layout.expandedGeometry : layout.collapsedGeometry
        let path = physicalPath(geometry).cgPath
        let fillPath = closedPhysicalPath(layout.fillGeometry(expanded: expanded)).cgPath
        let previousBorderPath = borderLayer.presentation()?.path ?? borderLayer.path
        let previousStripPath = stripLayer.presentation()?.path ?? stripLayer.path
        let previousFillPath = fillLayer.presentation()?.path ?? fillLayer.path
        let textLayers = [usageTextLayer, usageCaptionLayer, resetTextLayer, resetCaptionLayer]
        let previousTextPositions = textLayers.map { $0.presentation()?.position ?? $0.position }
        let previousTextOpacities = textLayers.map { $0.presentation()?.opacity ?? $0.opacity }
        collapseTask?.cancel()
        collapseTask = nil
        renderGeneration &+= 1
        let generation = renderGeneration

        borderLayer.removeAllAnimations()
        stripLayer.removeAllAnimations()
        fillLayer.removeAllAnimations()
        usageContainer.removeAllAnimations()
        resetContainer.removeAllAnimations()
        usageTextLayer.removeAllAnimations()
        usageCaptionLayer.removeAllAnimations()
        resetTextLayer.removeAllAnimations()
        resetCaptionLayer.removeAllAnimations()
        rootLayer.masksToBounds = false
        borderLayer.frame = bounds
        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.strokeColor = color.cgColor
        borderLayer.lineWidth = lineWidth
        borderLayer.lineCap = .round
        borderLayer.lineJoin = .round
        borderLayer.strokeStart = strokeRange.start
        borderLayer.strokeEnd = strokeRange.end
        borderLayer.isHidden = !isEnabled || strokeRange.isEmpty

        stripLayer.frame = bounds
        stripLayer.fillColor = NSColor.clear.cgColor
        stripLayer.strokeColor = strips.color.withAlphaComponent(strips.opacity).cgColor
        stripLayer.lineWidth = strips.thickness
        stripLayer.lineCap = .butt
        stripLayer.lineJoin = .miter
        stripLayer.isHidden = !isEnabled || !strips.isEnabled

        if glow {
            borderLayer.shadowColor = color.cgColor
            borderLayer.shadowOpacity = pulse && !strokeRange.isEmpty && !reduceMotion ? 0.25 : 0.78
            borderLayer.shadowRadius = pulse && !strokeRange.isEmpty && !reduceMotion ? 3 : 7
            borderLayer.shadowOffset = .zero
        } else {
            borderLayer.shadowOpacity = 0
        }
        borderLayer.path = path
        stripLayer.path = stripPath(
            for: path,
            topEdgeY: geometry.topY - globalOrigin.y,
            topPadding: strips.topPadding
        )
        if fillLayer.superlayer == nil { rootLayer.addSublayer(fillLayer) }
        if stripLayer.superlayer == nil { rootLayer.addSublayer(stripLayer) }
        if borderLayer.superlayer == nil { rootLayer.addSublayer(borderLayer) }
        fillLayer.frame = bounds
        fillLayer.path = fillPath
        fillLayer.fillColor = NSColor.black.cgColor
        fillLayer.strokeColor = NSColor.clear.cgColor
        // The fill and hover text remain interactive even when the user has
        // disabled the red border and ruler ticks.
        fillLayer.isHidden = !(expanded || keepFillDuringCollapse) || content.isEmpty
        configureContentLayers(
            layout: layout,
            expanded: expanded,
            animated: animated,
            previousPositions: previousTextPositions,
            previousOpacities: previousTextOpacities
        )

        if animated {
            let timing = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            animatePath(layer: borderLayer, from: previousBorderPath, to: path, timing: timing, duration: expanded ? 0.42 : 0.28)
            animatePath(layer: stripLayer, from: previousStripPath, to: stripLayer.path, timing: timing, duration: expanded ? 0.42 : 0.28)
            animatePath(layer: fillLayer, from: previousFillPath, to: fillPath, timing: timing, duration: expanded ? 0.42 : 0.28)
            if keepFillDuringCollapse {
                // The glow repeats forever, so transaction completion cannot
                // be used as the completion signal for this finite transition.
                collapseTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .milliseconds(280)) }
                    catch { return }
                    guard let self, self.renderGeneration == generation, !self.isExpanded else { return }
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.fillLayer.isHidden = true
                    CATransaction.commit()
                    self.collapseTask = nil
                }
            }
        }
        installPulseIfNeeded()

    }

    private func animatePath(layer: CAShapeLayer, from: CGPath?, to: CGPath?, timing: CAMediaTimingFunction, duration: CFTimeInterval) {
        guard let from, let to else { return }
        let animation = CABasicAnimation(keyPath: "path")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = timing
        layer.add(animation, forKey: "hoverPath")
    }

    private func configureContentLayers(
        layout: OverlayHoverLayout,
        expanded: Bool,
        animated: Bool,
        previousPositions: [CGPoint],
        previousOpacities: [Float]
    ) {
        let containers = [usageContainer, resetContainer]
        for container in containers {
            if container.superlayer == nil { layer?.addSublayer(container) }
            container.masksToBounds = true
            container.backgroundColor = NSColor.clear.cgColor
        }
        let textLayers = [usageTextLayer, usageCaptionLayer, resetTextLayer, resetCaptionLayer]
        for textLayer in textLayers {
            textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            textLayer.alignmentMode = .center
            textLayer.isWrapped = false
            textLayer.foregroundColor = NSColor.white.cgColor
        }
        usageTextLayer.font = hoverStyle.mainFont
        usageTextLayer.fontSize = hoverStyle.mainFont.pointSize
        resetTextLayer.font = hoverStyle.mainFont
        resetTextLayer.fontSize = hoverStyle.mainFont.pointSize
        usageCaptionLayer.font = hoverStyle.captionFont
        usageCaptionLayer.fontSize = hoverStyle.captionFont.pointSize
        resetCaptionLayer.font = hoverStyle.captionFont
        resetCaptionLayer.fontSize = hoverStyle.captionFont.pointSize
        usageTextLayer.string = content.usageText
        usageCaptionLayer.string = content.usageCaption
        resetTextLayer.string = content.resetText
        resetCaptionLayer.string = content.resetCaption

        let leftTarget = layout.leftWingRect.offsetBy(dx: -globalOrigin.x, dy: -globalOrigin.y)
        let rightTarget = layout.rightWingRect.offsetBy(dx: -globalOrigin.x, dy: -globalOrigin.y)
        // Clip each side at the camera edge. Text starts behind the camera
        // and moves outward at the same pace as the expanding black shape.
        usageContainer.frame = leftTarget
        resetContainer.frame = rightTarget
        let wingRects = [leftTarget, leftTarget, rightTarget, rightTarget]
        let targetOpacity: Float = expanded && !content.isEmpty ? 1 : 0
        let timing = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        for (index, textLayer) in textLayers.enumerated() {
            let container = index < 2 ? usageContainer : resetContainer
            let wing = wingRects[index]
            let isCaption = index % 2 == 1
            // Fit both rows within the physical notch's existing height.
            let height = isCaption ? hoverStyle.captionRowHeight : hoverStyle.mainRowHeight
            let groupBottom = max(0, (wing.height - hoverStyle.contentHeight) / 2)
            let y = groupBottom + (isCaption ? 0 : hoverStyle.captionRowHeight + hoverStyle.rowSpacing)
            textLayer.bounds = CGRect(x: 0, y: 0, width: max(1, wing.width - hoverStyle.horizontalInset * 2), height: height)
            let travel = index < 2 ? wing.width : -wing.width
            let position = CGPoint(
                x: wing.width / 2 + (expanded ? 0 : travel),
                y: y + height / 2
            )
            textLayer.position = position
            textLayer.opacity = targetOpacity
            if textLayer.superlayer !== container { container.addSublayer(textLayer) }
            if animated {
                let slide = CABasicAnimation(keyPath: "position")
                slide.fromValue = previousPositions[index]
                slide.toValue = position
                slide.duration = expanded ? 0.42 : 0.28
                slide.timingFunction = timing
                textLayer.add(slide, forKey: "hoverPosition")
                animateOpacity(layer: textLayer, from: previousOpacities[index], to: targetOpacity,
                               timing: timing, duration: slide.duration)
            }
        }
    }

    private func animateOpacity(layer: CALayer, from: Float, to: Float, timing: CAMediaTimingFunction, duration: CFTimeInterval) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = timing
        layer.add(animation, forKey: "hoverOpacity")
    }

    private func installPulseIfNeeded() {
        borderLayer.removeAnimation(forKey: "borderPulseOpacity")
        borderLayer.removeAnimation(forKey: "borderPulseRadius")
        let pulseActive = glow && pulse && !strokeRange.isEmpty && !reduceMotion
        diagnostics.updateContext(["pulse.animationActive": .bool(pulseActive)])
        guard pulseActive else { return }

        let duration = 1.8
        let now = CACurrentMediaTime()
        let phase = now.truncatingRemainder(dividingBy: duration)
        let opacity = CAKeyframeAnimation(keyPath: "shadowOpacity")
        opacity.values = [0.25, 1.0, 0.25]
        opacity.keyTimes = [0, 0.5, 1]
        opacity.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        opacity.duration = duration
        opacity.repeatCount = .infinity
        opacity.beginTime = now - phase
        opacity.isRemovedOnCompletion = false

        let radius = CAKeyframeAnimation(keyPath: "shadowRadius")
        radius.values = [3, 12, 3]
        radius.keyTimes = [0, 0.5, 1]
        radius.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        radius.duration = duration
        radius.repeatCount = .infinity
        radius.beginTime = now - phase
        radius.isRemovedOnCompletion = false

        borderLayer.add(opacity, forKey: "borderPulseOpacity")
        borderLayer.add(radius, forKey: "borderPulseRadius")
    }

    private func stripPath(for path: CGPath?, topEdgeY: CGFloat?, topPadding: CGFloat) -> CGPath? {
        guard strips.isEnabled, let path else { return nil }
        let segments = BorderStripGeometry.segments(
            for: path,
            fractions: BorderStripGeometry.standardFractions,
            length: Double(strips.length),
            offset: Double(strips.offset),
            topPadding: Double(topPadding),
            thickness: Double(strips.thickness),
            topEdgeY: topEdgeY.map(Double.init)
        )
        let markerPath = CGMutablePath()
        for segment in segments {
            markerPath.move(to: segment.start)
            markerPath.addLine(to: segment.end)
        }
        return markerPath
    }

    private func physicalPath(_ geometry: PhysicalBorderGeometry) -> NSBezierPath {
        let path = NSBezierPath()
        func local(_ point: CGPoint) -> NSPoint {
            NSPoint(x: point.x - globalOrigin.x, y: point.y - globalOrigin.y)
        }

        let radius = geometry.cornerRadius
        let k: CGFloat = 0.55228475

        // Ordered from top-left down the U and back up to top-right. CAShapeLayer
        // strokeStart/strokeEnd therefore map directly to user percentages.
        path.move(to: local(CGPoint(x: geometry.leftX, y: geometry.topY)))
        path.line(to: local(CGPoint(x: geometry.leftX, y: geometry.bottomY + radius)))
        path.curve(
            to: local(geometry.leftBottomArcEnd),
            controlPoint1: local(CGPoint(x: geometry.leftX, y: geometry.bottomY + radius * (1 - k))),
            controlPoint2: local(CGPoint(x: geometry.leftX + radius * (1 - k), y: geometry.bottomY))
        )
        path.line(to: local(geometry.rightBottomArcStart))
        path.curve(
            to: local(CGPoint(x: geometry.rightX, y: geometry.bottomY + radius)),
            controlPoint1: local(CGPoint(x: geometry.rightX - radius * (1 - k), y: geometry.bottomY)),
            controlPoint2: local(CGPoint(x: geometry.rightX, y: geometry.bottomY + radius * (1 - k)))
        )
        path.line(to: local(CGPoint(x: geometry.rightX, y: geometry.topY)))
        return path
    }

    private func closedPhysicalPath(_ geometry: PhysicalBorderGeometry) -> NSBezierPath {
        let path = physicalPath(geometry)
        path.line(to: NSPoint(x: geometry.rightX - globalOrigin.x, y: geometry.topY - globalOrigin.y))
        path.line(to: NSPoint(x: geometry.leftX - globalOrigin.x, y: geometry.topY - globalOrigin.y))
        path.close()
        return path
    }

}
