import Foundation
import AppKit
import Testing
@testable import BorderOverlay

struct OverlayGeometryTests {
    @Test("notch geometry respects a display with a negative global origin")
    func negativeOriginAndMultipleDisplays() {
        let frame = CGRect(x: -1920, y: 180, width: 1920, height: 1080)
        let input = DisplayGeometryInput(
            frame: frame,
            safeTopInset: 37,
            auxiliaryTopLeftArea: CGRect(x: -1920, y: 1223, width: 820, height: 37),
            auxiliaryTopRightArea: CGRect(x: -580, y: 1223, width: 580, height: 37)
        )

        let notch = OverlayGeometry.physicalNotch(in: input)

        #expect(notch?.rect == CGRect(x: -1100, y: 1223, width: 520, height: 37))
        #expect(notch?.rect.maxX == -580)
    }

    @Test("zero safe area and empty auxiliary areas mean no physical notch")
    func noNotch() {
        let input = DisplayGeometryInput(frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), safeTopInset: 0)
        #expect(OverlayGeometry.physicalNotch(in: input) == nil)
    }

    @Test("border stays outside the opaque camera opening with a flat bottom")
    func borderAvoidsOpaqueCamera() throws {
        let input = DisplayGeometryInput(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            safeTopInset: 37,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 945, width: 670, height: 37),
            auxiliaryTopRightArea: CGRect(x: 842, y: 945, width: 670, height: 37)
        )
        let notch = try #require(OverlayGeometry.physicalNotch(in: input))
        let border = OverlayGeometry.physicalBorder(in: input, notch: notch, lineWidth: 1, padding: 4)
        #expect(border.topY == input.frame.maxY)

        #expect(border.leftX == notch.left - 4.5)
        #expect(border.rightX == notch.right + 4.5)
        #expect(border.bottomY == notch.bottom - 4.5)
        #expect(border.leftBottomArcEnd.y == border.rightBottomArcStart.y)
        #expect(border.leftBottomArcEnd.x < border.rightBottomArcStart.x)
    }

    @Test("line widths are kept visible and bounded")
    func lineWidths() {
        #expect(OverlayGeometry.normalizedLineWidth(0) == 0.5)
        #expect(OverlayGeometry.normalizedLineWidth(2.5) == 2.5)
        #expect(OverlayGeometry.normalizedLineWidth(100) == 16)
        #expect(OverlayGeometry.normalizedLineWidth(.infinity) == 1)
    }

    @Test("stroke percentages clamp, normalize crossings, and allow an empty range")
    func strokePercentages() {
        #expect(OverlayGeometry.normalizedStrokeRange(start: 0, end: 100) == .init(start: 0, end: 1))
        #expect(OverlayGeometry.normalizedStrokeRange(start: 20, end: 80) == .init(start: 0.2, end: 0.8))
        #expect(OverlayGeometry.normalizedStrokeRange(start: 90, end: 10) == .init(start: 0.1, end: 0.9))
        #expect(OverlayGeometry.normalizedStrokeRange(start: -10, end: 120) == .init(start: 0, end: 1))
        #expect(OverlayGeometry.normalizedStrokeRange(start: .nan, end: .infinity) == .init(start: 0, end: 1))

        let empty = OverlayGeometry.normalizedStrokeRange(start: 40, end: 40)
        #expect(empty.isEmpty)
        #expect(empty.start == empty.end)
    }

    @MainActor
    @Test("CAShapeLayer applies the normalized range to the real border path")
    func renderedStrokeRange() throws {
        let input = DisplayGeometryInput(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            safeTopInset: 32,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: 663.5, height: 32),
            auxiliaryTopRightArea: CGRect(x: 848.5, y: 950, width: 663.5, height: 32)
        )
        let notch = try #require(OverlayGeometry.physicalNotch(in: input))
        let border = OverlayGeometry.physicalBorder(in: input, notch: notch, lineWidth: 2, padding: 2)
        let view = OverlayView(
            frame: CGRect(x: 0, y: 900, width: 200, height: 82),
            drawing: .physical(border),
            lineWidth: 2,
            glow: false,
            padding: 2,
            strokeRange: .init(start: 0.2, end: 0.8),
            color: .systemRed,
            globalOrigin: .zero
        )
        let borderLayer = try #require(view.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first { $0.name == "border" })

        #expect(borderLayer.path != nil)
        #expect(borderLayer.strokeStart == 0.2)
        #expect(borderLayer.strokeEnd == 0.8)
    }

}
