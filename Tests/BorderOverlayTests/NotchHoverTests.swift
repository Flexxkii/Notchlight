import AppKit
import Testing
@testable import BorderOverlay

struct NotchHoverTests {
    private let geometry = PhysicalBorderGeometry(
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        notch: NotchGeometry(rect: CGRect(x: 663.5, y: 950, width: 185, height: 32)),
        leftX: 661,
        rightX: 851,
        topY: 982,
        bottomY: 948,
        cornerRadius: 8
    )

    @Test("hover layout expands both wings without increasing the camera height")
    func layoutExpandsSymmetrically() {
        let content = NotchHoverContent(
            usageText: "42%",
            usageCaption: "5-HOUR USAGE",
            resetText: "1h 18m",
            resetCaption: "RESET"
        )
        let layout = NotchHoverGeometry.layout(for: geometry, content: content)
        #expect(layout.expandedGeometry.leftX < geometry.leftX)
        #expect(layout.expandedGeometry.rightX > geometry.rightX)
        // Hover expands only horizontally: the camera opening's vertical
        // contour and corner radius stay exactly unchanged.
        #expect(layout.expandedGeometry.topY == geometry.topY)
        #expect(layout.expandedGeometry.bottomY == geometry.bottomY)
        #expect(layout.expandedGeometry.topY - layout.expandedGeometry.bottomY == geometry.topY - geometry.bottomY)
        #expect(layout.expandedGeometry.cornerRadius == geometry.cornerRadius)
        #expect(layout.leftWingRect.minY == geometry.notch.bottom)
        #expect(layout.rightWingRect.minY == geometry.notch.bottom)
        #expect(layout.leftWingRect.height == geometry.notch.depth)
        #expect(layout.rightWingRect.height == geometry.notch.depth)
        #expect(layout.expandedHitRect.minY == layout.collapsedHitRect.minY)
        #expect(layout.expandedHitRect.maxY == layout.collapsedHitRect.maxY)
        #expect(layout.expandedHitRect.height == layout.collapsedHitRect.height)
        #expect(layout.expandedHitRect.contains(layout.leftWingRect.midPoint))
        #expect(layout.expandedHitRect.contains(layout.rightWingRect.midPoint))
    }

    @MainActor
    @Test("hover fill stays within the camera height throughout expansion and collapse",
          arguments: [0.5, 2.0, 16.0], [0.0, 4.0, 32.0])
    func fillPreservesCameraHeight(lineWidth: Double, padding: Double) throws {
        let display = DisplayGeometryInput(
            frame: CGRect(x: -1512, y: 180, width: 1512, height: 982), safeTopInset: 32
        )
        let notch = NotchGeometry(rect: CGRect(x: -848.5, y: 1130, width: 185, height: 32))
        let border = OverlayGeometry.physicalBorder(
            in: display, notch: notch, lineWidth: lineWidth, padding: padding
        )
        let content = NotchHoverContent(
            usageText: "52% used", usageCaption: "Weekly usage",
            resetText: "19 Sep at 23:38", resetCaption: "Resets"
        )
        let panel = OverlayView.panelFrame(for: border, content: content, margin: 32)
        let view = OverlayView(
            frame: CGRect(origin: .zero, size: panel.size), drawing: .physical(border),
            lineWidth: lineWidth, glow: false, pulse: false, padding: padding,
            strokeRange: .init(start: 0, end: 1), color: .systemRed,
            strips: BorderStripStyle(isEnabled: false), reduceMotion: false,
            globalOrigin: panel.origin, content: content, isEnabled: false
        )
        let fill = try #require(view.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first { $0.name == "fill" })
        let bottom = notch.bottom - panel.minY
        let top = notch.top - panel.minY

        // Include the starting path, both animated directions, and a reversal.
        // A hidden border must not contribute its padding or half-stroke to the fill.
        for expanded in [true, false, true] {
            view.setExpanded(expanded, animated: true)
            let animation = try #require(fill.animation(forKey: "hoverPath") as? CABasicAnimation)
            let from = try #require(animation.fromValue) as! CGPath
            let to = try #require(animation.toValue) as! CGPath
            for path in [from, to, try #require(fill.path)] {
                #expect(abs(path.boundingBoxOfPath.minY - bottom) < 0.001)
                #expect(abs(path.boundingBoxOfPath.maxY - top) < 0.001)
            }
            // Matching Y coordinates for every control point keep interpolation
            // horizontal for the entire animation, including rounded corners.
            #expect(pathCoordinates(from).map(\.y) == pathCoordinates(to).map(\.y))
        }
        for name in ["usage", "reset"] {
            let container = try #require(view.layer?.sublayers?.first { $0.name == name })
            #expect(container.frame.minY == bottom)
            #expect(container.frame.maxY == top)
        }
        view.setExpanded(false, animated: false)
        #expect(fill.isHidden)
    }

    private func pathCoordinates(_ path: CGPath) -> [CGPoint] {
        var points: [CGPoint] = []
        path.applyWithBlock { element in
            let count: Int
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint: count = 1
            case .addQuadCurveToPoint: count = 2
            case .addCurveToPoint: count = 3
            case .closeSubpath: count = 0
            @unknown default: count = 0
            }
            points.append(contentsOf: UnsafeBufferPointer(start: element.pointee.points, count: count))
        }
        return points
    }

    @MainActor
    @Test("setExpanded morphs the border and reveals the content fill")
    func expansionMorphsLayers() throws {
        let view = OverlayView(
            frame: CGRect(x: 0, y: 900, width: 600, height: 82),
            drawing: .physical(geometry),
            lineWidth: 2,
            glow: false,
            pulse: false,
            padding: 0,
            strokeRange: .init(start: 0, end: 1),
            color: .systemRed,
            strips: BorderStripStyle(isEnabled: false),
            reduceMotion: false,
            globalOrigin: .zero,
            content: NotchHoverContent(usageText: "42%", resetText: "1h 18m"),
            isEnabled: true
        )
        let collapsed = view.collapsedHitRect
        view.setExpanded(true, animated: false)
        #expect(view.expandedHitRect.width > collapsed.width)
        let fill = try #require(view.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
        #expect(!fill.isHidden)
        #expect(fill.path != nil)
        view.setExpanded(false, animated: true)
        #expect(fill.animation(forKey: "hoverPath") != nil)
    }

    @MainActor
    @Test("hover size changes update text, panel bounds, and hit regions together")
    func sizeChangesUpdateExpandedContent() throws {
        let view = pulseViewForHover()
        view.setExpanded(true, animated: false)
        let originalCollapsedHitRect = view.collapsedHitRect
        let content = NotchHoverContent(
            usageText: "42% used", usageCaption: "5-hour usage",
            resetText: "16 Sep, 23:38", resetCaption: "Last known reset"
        )
        var widths: [CGFloat] = []
        for size in [14.0, 12.0, 10.0, 14.0] {
            let style = NotchHoverStyle(textSize: size)
            view.updateAppearance(
                lineWidth: 2, glow: false, pulse: false, padding: 0,
                strokeRange: .init(start: 0, end: 1), color: .systemRed,
                strips: BorderStripStyle(isEnabled: false), reduceMotion: true,
                content: content, hoverStyle: style, isEnabled: true
            )
            let layout = NotchHoverGeometry.layout(for: geometry, content: content, style: style)
            let panel = OverlayView.panelFrame(for: geometry, content: content, margin: 32, style: style)
            #expect(panel.contains(layout.expandedHitRect))
            #expect(view.expandedHitRect == layout.expandedHitRect)
            #expect(view.collapsedHitRect == originalCollapsedHitRect)
            widths.append(view.expandedHitRect.width)
            for name in ["usage", "reset"] {
                let container = try #require(view.layer?.sublayers?.first { $0.name == name })
                let rows = try #require(container.sublayers?.compactMap { $0 as? CATextLayer })
                #expect(rows.count == 2)
                #expect(rows[0].fontSize == CGFloat(size))
                #expect(rows[1].fontSize >= 9)
                #expect(rows[1].frame.maxY <= rows[0].frame.minY)
                for row in rows {
                    #expect(container.bounds.contains(row.frame))
                    #expect(row.opacity == 1)
                    let font = try #require(row.font as? NSFont)
                    let string = try #require(row.string as? String)
                    #expect((string as NSString).size(withAttributes: [.font: font]).width <= row.bounds.width)
                }
            }
        }
        #expect(widths[0] > widths[1])
        #expect(widths[1] > widths[2])
        #expect(widths[0] == widths[3])
    }


    @MainActor
    @Test("overlay exposes an accessible Codex notch button")
    func accessibilitySurfaceAndPressAction() throws {
        let view = OverlayView(
            frame: CGRect(x: 0, y: 900, width: 700, height: 82),
            drawing: .physical(geometry),
            lineWidth: 2,
            glow: false,
            pulse: false,
            padding: 0,
            strokeRange: .init(start: 0, end: 1),
            color: .systemRed,
            strips: BorderStripStyle(isEnabled: false),
            reduceMotion: true,
            globalOrigin: .zero,
            content: NotchHoverContent(
                usageText: "42%",
                usageCaption: "USAGE",
                resetText: "1h",
                resetCaption: "RESET"
            ),
            isEnabled: false
        )
        var pressed = false
        view.onClick = { pressed = true }
        #expect(view.isAccessibilityElement())
        #expect(view.accessibilityRole() == .button)
        let value = try #require(view.accessibilityValue() as? String)
        #expect(value.contains("42%"))
        #expect(value.contains("1h"))
        #expect(view.accessibilityPerformPress())
        #expect(pressed)
    }

    @MainActor
    @Test("hover text slides from the camera into masked wings")
    func contentSlidesFromCollapsedNotch() throws {
        let view = pulseViewForHover()
        view.setExpanded(true, animated: true)
        let usage = try #require(view.layer?.sublayers?.first(where: { $0.name == "usage" }))
        #expect(usage.masksToBounds)
        #expect(usage.bounds.width > 1)
        let usageText = try #require(usage.sublayers?.compactMap { $0 as? CATextLayer }.first(where: { ($0.string as? String) == "42%" }))
        let usageAnimations = (usageText.animationKeys() ?? []).compactMap { usageText.animation(forKey: $0) as? CABasicAnimation }
        let usagePosition = try #require(usageAnimations.first(where: { $0.keyPath == "position" }))
        let usageFrom = try #require(usagePosition.fromValue as? CGPoint)
        let usageTo = try #require(usagePosition.toValue as? CGPoint)
        #expect(usageTo.x < usageFrom.x)
        #expect(abs(usageTo.y - usageFrom.y) < 0.001)
        #expect(usageAnimations.contains(where: { $0.keyPath == "opacity" }))
        #expect(usageText.fontSize == 12)
        let usageCaption = try #require(usage.sublayers?.compactMap { $0 as? CATextLayer }.first(where: { ($0.string as? String) == "USAGE" }))
        #expect(usageCaption.fontSize == 9)
        #expect(usageText.frame.minY >= -0.001)
        #expect(usageCaption.frame.minY >= -0.001)
        #expect(usageText.frame.maxY <= usage.bounds.height + 0.001)
        #expect(usageCaption.frame.maxY <= usage.bounds.height + 0.001)
        #expect(usageCaption.frame.maxY <= usageText.frame.minY + 0.001)

        let reset = try #require(view.layer?.sublayers?.first(where: { $0.name == "reset" }))
        #expect(reset.masksToBounds)
        let resetText = try #require(reset.sublayers?.compactMap { $0 as? CATextLayer }.first(where: { ($0.string as? String) == "1h 18m" }))
        let resetAnimations = (resetText.animationKeys() ?? []).compactMap { resetText.animation(forKey: $0) as? CABasicAnimation }
        let resetPosition = try #require(resetAnimations.first(where: { $0.keyPath == "position" }))
        let resetFrom = try #require(resetPosition.fromValue as? CGPoint)
        let resetTo = try #require(resetPosition.toValue as? CGPoint)
        #expect(resetTo.x > resetFrom.x)
        #expect(abs(resetTo.y - resetFrom.y) < 0.001)
        #expect(resetAnimations.contains(where: { $0.keyPath == "opacity" }))
        let resetCaption = try #require(reset.sublayers?.compactMap { $0 as? CATextLayer }.first(where: { ($0.string as? String) == "RESET" }))
        #expect(resetCaption.frame.maxY <= reset.bounds.height + 0.001)
    }

    @MainActor
    @Test("expanded hover remains visible when border visuals are disabled")
    func disabledBorderStillShowsHoverContent() throws {
        let view = OverlayView(
            frame: CGRect(x: 0, y: 900, width: 700, height: 82),
            drawing: .physical(geometry),
            lineWidth: 2,
            glow: false,
            pulse: false,
            padding: 0,
            strokeRange: .init(start: 0, end: 1),
            color: .systemRed,
            strips: BorderStripStyle(),
            reduceMotion: true,
            globalOrigin: .zero,
            content: NotchHoverContent(usageText: "42%", resetText: "1h"),
            isEnabled: false
        )
        view.setExpanded(true, animated: false)
        let layers = try #require(view.layer?.sublayers?.compactMap { $0 as? CAShapeLayer })
        let fill = try #require(layers.first(where: { $0.name == "fill" }))
        let border = try #require(layers.first(where: { $0.name == "border" }))
        #expect(!fill.isHidden)
        #expect(border.isHidden)
    }

    @MainActor
    @Test("collapse cleanup completes while the busy pulse repeats")
    func collapseCleanupRunsAlongsidePulse() async throws {
        let view = busyHoverView()
        view.setExpanded(true, animated: false)
        view.setExpanded(false, animated: true)
        try await Task.sleep(for: .milliseconds(340))
        let fill = try #require(view.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first(where: { $0.name == "fill" }))
        let border = try #require(view.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first(where: { $0.name == "border" }))
        #expect(fill.isHidden)
        #expect(border.animation(forKey: "borderPulseOpacity") != nil)
    }

    @MainActor
    @Test("reversing after collapse cancels stale fill cleanup")
    func reversalKeepsExpandedFillVisible() async throws {
        let view = busyHoverView()
        view.setExpanded(true, animated: true)
        view.setExpanded(false, animated: true)
        view.setExpanded(true, animated: true)
        try await Task.sleep(for: .milliseconds(340))
        let fill = try #require(view.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first(where: { $0.name == "fill" }))
        #expect(!fill.isHidden)
    }

    @MainActor
    @Test("disabled appearance keeps hover hit geometry but hides visual layers")
    func disabledVisualsRemainInteractive() throws {
        let view = OverlayView(
            frame: CGRect(x: 0, y: 900, width: 600, height: 82),
            drawing: .physical(geometry),
            lineWidth: 2,
            glow: false,
            pulse: false,
            padding: 0,
            strokeRange: .init(start: 0, end: 1),
            color: .systemRed,
            strips: BorderStripStyle(),
            reduceMotion: true,
            globalOrigin: .zero,
            content: NotchHoverContent(usageText: "42%"),
            isEnabled: true
        )
        let before = view.expandedHitRect
        view.updateAppearance(
            lineWidth: 2,
            glow: false,
            pulse: false,
            padding: 0,
            strokeRange: .init(start: 0, end: 1),
            color: .systemRed,
            strips: BorderStripStyle(),
            reduceMotion: true,
            content: NotchHoverContent(usageText: "42%"),
            isEnabled: false
        )
        #expect(view.expandedHitRect == before)
        let layers = try #require(view.layer?.sublayers?.compactMap { $0 as? CAShapeLayer })
        #expect(layers.contains(where: { $0.isHidden }))
    }

    @MainActor
    @Test("hit rectangles are view-local when the panel has a global origin")
    func hitRegionsUseLocalCoordinates() {
        let view = OverlayView(
            frame: CGRect(x: 0, y: 0, width: 700, height: 100),
            drawing: .physical(geometry),
            lineWidth: 2,
            glow: false,
            pulse: false,
            padding: 0,
            strokeRange: .init(start: 0, end: 1),
            color: .systemRed,
            strips: BorderStripStyle(isEnabled: false),
            reduceMotion: true,
            globalOrigin: CGPoint(x: 100, y: 900),
            content: NotchHoverContent(usageText: "42%"),
            isEnabled: true
        )
        #expect(view.collapsedHitRect.minX == geometry.leftX - 100)
        #expect(view.collapsedHitRect.minY == geometry.bottomY - 900 - 8)
        #expect(view.expandedHitRect.maxX < geometry.screenFrame.maxX)
    }

    @MainActor
    @Test("reversing a hover transition keeps a path animation from the current shape")
    func interruptedExpansionReversesSmoothly() throws {
        let view = pulseViewForHover()
        view.setExpanded(true, animated: true)
        view.setExpanded(false, animated: true)
        let border = try #require(view.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first { $0.animation(forKey: "hoverPath") != nil })
        let animation = try #require(border.animation(forKey: "hoverPath") as? CABasicAnimation)
        #expect(animation.fromValue != nil)
        #expect(animation.toValue != nil)
    }

    @MainActor
    private func busyHoverView() -> OverlayView {
        OverlayView(
            frame: CGRect(x: 0, y: 900, width: 700, height: 82),
            drawing: .physical(geometry),
            lineWidth: 2,
            glow: true,
            pulse: true,
            padding: 0,
            strokeRange: .init(start: 0, end: 1),
            color: .systemRed,
            strips: BorderStripStyle(isEnabled: false),
            reduceMotion: false,
            globalOrigin: .zero,
            content: NotchHoverContent(usageText: "42%", usageCaption: "USAGE", resetText: "1h", resetCaption: "RESET"),
            isEnabled: true
        )
    }

    @MainActor
    private func pulseViewForHover() -> OverlayView {
        OverlayView(
            frame: CGRect(x: 0, y: 900, width: 700, height: 82),
            drawing: .physical(geometry),
            lineWidth: 2,
            glow: false,
            pulse: false,
            padding: 0,
            strokeRange: .init(start: 0, end: 1),
            color: .systemRed,
            strips: BorderStripStyle(isEnabled: false),
            reduceMotion: false,
            globalOrigin: .zero,
            content: NotchHoverContent(
                usageText: "42%",
                usageCaption: "USAGE",
                resetText: "1h 18m",
                resetCaption: "RESET"
            ),
            isEnabled: true
        )
    }
}

private extension CGRect {
    var midPoint: CGPoint { CGPoint(x: midX, y: midY) }
}
