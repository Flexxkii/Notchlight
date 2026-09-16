import Foundation

/// The small, Sendable subset of NSScreen information needed to calculate an
/// overlay. Keeping this separate from NSScreen makes the geometry testable
/// without needing to manufacture AppKit screen objects.
struct DisplayGeometryInput: Equatable, Sendable {
    let frame: CGRect
    let safeTopInset: CGFloat
    let auxiliaryTopLeftArea: CGRect
    let auxiliaryTopRightArea: CGRect
    let visibleFrame: CGRect

    init(
        frame: CGRect,
        safeTopInset: CGFloat,
        auxiliaryTopLeftArea: CGRect = .zero,
        auxiliaryTopRightArea: CGRect = .zero,
        visibleFrame: CGRect? = nil
    ) {
        self.frame = frame
        self.safeTopInset = safeTopInset
        self.auxiliaryTopLeftArea = auxiliaryTopLeftArea
        self.auxiliaryTopRightArea = auxiliaryTopRightArea
        self.visibleFrame = visibleFrame ?? frame
    }
}

struct NotchGeometry: Equatable, Sendable {
    let rect: CGRect

    var left: CGFloat { rect.minX }
    var right: CGFloat { rect.maxX }
    var bottom: CGFloat { rect.minY }
    var top: CGFloat { rect.maxY }
    var width: CGFloat { rect.width }
    var depth: CGFloat { rect.height }
}

/// Geometry for the two short sides and rounded bottom of a notch outline.
struct PhysicalBorderGeometry: Equatable, Sendable {
    let screenFrame: CGRect
    let notch: NotchGeometry
    let leftX: CGFloat
    let rightX: CGFloat
    let topY: CGFloat
    let bottomY: CGFloat
    let cornerRadius: CGFloat

    var leftBottomArcEnd: CGPoint { CGPoint(x: leftX + cornerRadius, y: bottomY) }
    var rightBottomArcStart: CGPoint { CGPoint(x: rightX - cornerRadius, y: bottomY) }
}

enum OverlayGeometry {
    struct StrokeRange: Equatable, Sendable {
        let start: CGFloat
        let end: CGFloat

        var isEmpty: Bool { start >= end }
    }

    static func normalizedStrokeRange(start: CGFloat, end: CGFloat) -> StrokeRange {
        let normalizedStart = start.isFinite ? min(max(start, 0), 100) : 0
        let normalizedEnd = end.isFinite ? min(max(end, 0), 100) : 100
        let low = min(normalizedStart, normalizedEnd)
        let high = max(normalizedStart, normalizedEnd)
        return StrokeRange(start: low / 100, end: high / 100)
    }

    static func physicalNotch(in display: DisplayGeometryInput) -> NotchGeometry? {
        let frame = display.frame.standardized
        let leftArea = display.auxiliaryTopLeftArea.standardized
        let rightArea = display.auxiliaryTopRightArea.standardized

        // A real notch is represented by a positive top safe-area inset and
        // two unobscured top areas separated by an opaque central gap.
        guard display.safeTopInset > 0.5,
              !leftArea.isEmpty,
              !rightArea.isEmpty else {
            return nil
        }

        let left = max(frame.minX, min(leftArea.maxX, frame.maxX))
        let right = min(frame.maxX, max(rightArea.minX, frame.minX))
        let depth = min(display.safeTopInset, frame.height)
        guard right - left > 1, depth > 0 else { return nil }

        return NotchGeometry(
            rect: CGRect(x: left, y: frame.maxY - depth, width: right - left, height: depth)
        )
    }

    static func physicalBorder(
        in display: DisplayGeometryInput,
        notch: NotchGeometry,
        lineWidth: CGFloat,
        padding: CGFloat
    ) -> PhysicalBorderGeometry {
        let frame = display.frame.standardized
        let width = normalizedLineWidth(lineWidth)
        let inset = normalizedPadding(padding)

        // Both sides meet the top edge of the display. There is no horizontal
        // line across the top of the camera or the rest of the menu bar.
        let topY = frame.maxY
        let leftX = max(frame.minX, notch.left - inset - width / 2)
        let rightX = min(frame.maxX, notch.right + inset + width / 2)
        let lowestVisibleY = frame.minY + width / 2
        let bottomY = max(lowestVisibleY, notch.bottom - inset - width / 2)
        let availableDepth = max(0, topY - bottomY)
        let cornerRadius = min(8 + inset + width / 2, availableDepth / 2, max(0, (rightX - leftX) / 2))

        return PhysicalBorderGeometry(
            screenFrame: frame,
            notch: notch,
            leftX: leftX,
            rightX: rightX,
            topY: topY,
            bottomY: bottomY,
            cornerRadius: cornerRadius
        )
    }

    static func normalizedLineWidth(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 1 }
        return min(max(value, 0.5), 16)
    }

    static func normalizedPadding(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 256)
    }
}
