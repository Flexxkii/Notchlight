import AppKit
import Testing
@testable import BorderOverlay

struct BorderStripGeometryTests {
    @Test("style fields normalize to the documented marker bounds")
    func styleNormalization() {
        let style = BorderStripStyle(
            thickness: -4,
            length: 100,
            offset: 100,
            topPadding: 100,
            color: .white,
            opacity: 4
        )
        #expect(style.thickness == 0.5)
        #expect(style.length == 20)
        #expect(style.offset == 24)
        #expect(style.topPadding == 12)
        #expect(style.opacity == 1)
    }

    @Test("markers follow cumulative contour length and point outward")
    func contourFractionsAndNormals() throws {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 10))
        path.addLine(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 10, y: 0))
        path.addLine(to: CGPoint(x: 10, y: 10))

        let segments = BorderStripGeometry.segments(
            for: path,
            fractions: [0, 0.5, 1],
            length: 8,
            offset: 2,
            topPadding: 2,
            topEdgeY: 10
        )
        #expect(segments.count == 3)

        let first = try #require(segments.first)
        #expect(first.center == CGPoint(x: -2, y: 8))
        #expect(first.outwardNormal == CGVector(dx: -1, dy: 0))
        #expect(first.start == CGPoint(x: 2, y: 8))
        #expect(first.end == CGPoint(x: -6, y: 8))

        let middle = segments[1]
        #expect(abs(middle.center.x - 5) < 0.001)
        #expect(middle.center.y == -2)
        #expect(middle.outwardNormal == CGVector(dx: 0, dy: -1))

        let last = try #require(segments.last)
        #expect(last.center == CGPoint(x: 12, y: 8))
        #expect(last.outwardNormal == CGVector(dx: 1, dy: 0))
    }

    @Test("closed contour endpoints coincide and produce one marker")
    func closedContourDeduplicatesEndpoints() {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 5, y: 10))
        path.addLine(to: CGPoint(x: 10, y: 10))
        path.addLine(to: CGPoint(x: 10, y: 0))
        path.addLine(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: 10))
        path.addLine(to: CGPoint(x: 5, y: 10))
        path.closeSubpath()

        let segments = BorderStripGeometry.segments(for: path, length: 8)
        #expect(segments.count == 4)
        #expect(segments.first?.fraction == 0)
        #expect(!segments.contains(where: { $0.fraction == 1 }))

        let offset = BorderStripGeometry.segments(for: path, length: 8, offset: 2)
        #expect(offset[0].center.y > 10)
        #expect(offset[1].center.x > 10)
        #expect(offset[2].center.y < 0)
        #expect(offset[3].center.x < 0)
    }

    @MainActor
    @Test("markers stay visible when the border progress is empty")
    func markersIgnoreEmptyProgress() throws {
        let geometry = PhysicalBorderGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            notch: NotchGeometry(rect: CGRect(x: 30, y: 70, width: 40, height: 30)),
            leftX: 28,
            rightX: 72,
            topY: 100,
            bottomY: 68,
            cornerRadius: 8
        )
        let view = OverlayView(
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            drawing: .physical(geometry),
            lineWidth: 2,
            glow: false,
            padding: 0,
            strokeRange: .init(start: 0.5, end: 0.5),
            color: .systemRed,
            strips: BorderStripStyle(),
            globalOrigin: .zero
        )
        let layers = try #require(view.layer?.sublayers?.compactMap { $0 as? CAShapeLayer })
        let markers = try #require(layers.first { $0.strokeColor == BorderStripStyle().color.withAlphaComponent(0.7).cgColor })
        #expect(!markers.isHidden)
        #expect(markers.path != nil)
    }

    @MainActor
    @Test("busy glow installs a continuous breath animation")
    func busyPulseAnimation() throws {
        let view = pulseView(pulse: true, glow: true, strokeRange: .init(start: 0, end: 1), reduceMotion: false)
        let border = try #require(view.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first { $0.name == "border" })
        let opacity = try #require(border.animation(forKey: "borderPulseOpacity"))
        let radius = try #require(border.animation(forKey: "borderPulseRadius"))
        #expect((opacity.value(forKey: "values") as? [NSNumber])?.map(\.doubleValue) == [0.25, 1, 0.25])
        #expect((radius.value(forKey: "values") as? [NSNumber])?.map(\.doubleValue) == [3, 12, 3])
        #expect(opacity.duration == 1.8)
        #expect(radius.duration == 1.8)
        #expect(opacity.repeatCount.isInfinite)
    }

    @MainActor
    @Test("pulse stops for idle, disabled, or reduced-motion states")
    func pulseGating() throws {
        for configuration in [
            (false, true, false), // pulse disabled
            (true, false, false), // glow disabled
            (true, true, true), // reduced motion
            (true, true, false) // empty progress, replaced below
        ] {
            let range = configuration.0 && configuration.1 && !configuration.2
                ? OverlayGeometry.StrokeRange(start: 0.4, end: 0.4)
                : OverlayGeometry.StrokeRange(start: 0, end: 1)
            let view = pulseView(
                pulse: configuration.0,
                glow: configuration.1,
                strokeRange: range,
                reduceMotion: configuration.2
            )
            let border = try #require(view.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first { $0.name == "border" })
            #expect(border.animation(forKey: "borderPulseOpacity") == nil)
            #expect(border.animation(forKey: "borderPulseRadius") == nil)
        }
    }

    @MainActor
    private func pulseView(
        pulse: Bool,
        glow: Bool,
        strokeRange: OverlayGeometry.StrokeRange,
        reduceMotion: Bool
    ) -> OverlayView {
        OverlayView(
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            drawing: .physical(PhysicalBorderGeometry(
                screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
                notch: NotchGeometry(rect: CGRect(x: 30, y: 70, width: 40, height: 30)),
                leftX: 28,
                rightX: 72,
                topY: 100,
                bottomY: 68,
                cornerRadius: 8
            )),
            lineWidth: 2,
            glow: glow,
            pulse: pulse,
            padding: 0,
            strokeRange: strokeRange,
            color: .systemRed,
            strips: BorderStripStyle(isEnabled: false),
            reduceMotion: reduceMotion,
            globalOrigin: .zero
        )
    }
}
