import AppKit

public struct NotchHoverContent: Equatable, Sendable {
    public var usageText: String
    public var usageCaption: String
    public var resetText: String
    public var resetCaption: String

    public init(
        usageText: String = "",
        usageCaption: String = "",
        resetText: String = "",
        resetCaption: String = ""
    ) {
        self.usageText = usageText
        self.usageCaption = usageCaption
        self.resetText = resetText
        self.resetCaption = resetCaption
    }

    var isEmpty: Bool {
        usageText.isEmpty && usageCaption.isEmpty && resetText.isEmpty && resetCaption.isEmpty
    }
}

struct OverlayHoverLayout: Equatable, Sendable {
    let collapsedGeometry: PhysicalBorderGeometry
    let expandedGeometry: PhysicalBorderGeometry
    let leftWingRect: CGRect
    let rightWingRect: CGRect
    let expandedHitRect: CGRect

    func fillGeometry(expanded: Bool) -> PhysicalBorderGeometry {
        let border = expanded ? expandedGeometry : collapsedGeometry
        let notch = collapsedGeometry.notch
        // The outline includes padding and half its stroke width below the
        // camera. Filling those bounds adds a visible lip on hover, even when
        // the border is disabled. Keep the fill at the camera's actual depth
        // in both animation endpoints so it only changes horizontally.
        return PhysicalBorderGeometry(
            screenFrame: border.screenFrame,
            notch: notch,
            leftX: border.leftX,
            rightX: border.rightX,
            topY: notch.top,
            bottomY: notch.bottom,
            cornerRadius: min(border.cornerRadius, notch.depth / 2)
        )
    }

    var collapsedHitRect: CGRect {
        CGRect(
            x: collapsedGeometry.leftX,
            y: max(collapsedGeometry.screenFrame.minY, collapsedGeometry.bottomY - 8),
            width: collapsedGeometry.rightX - collapsedGeometry.leftX,
            height: collapsedGeometry.topY - max(collapsedGeometry.screenFrame.minY, collapsedGeometry.bottomY - 8)
        )
    }
}

enum NotchHoverGeometry {
    static func expandedBorder(from geometry: PhysicalBorderGeometry, content: NotchHoverContent, style: NotchHoverStyle = NotchHoverStyle()) -> PhysicalBorderGeometry {
        layout(for: geometry, content: content, style: style).expandedGeometry
    }

    static func layout(for geometry: PhysicalBorderGeometry, content: NotchHoverContent, style: NotchHoverStyle = NotchHoverStyle()) -> OverlayHoverLayout {
        let leftWidth = wingWidth(for: [content.usageText, content.usageCaption], style: style)
        let rightWidth = wingWidth(for: [content.resetText, content.resetCaption], style: style)
        let maxCombined = 500 - geometry.notch.width
        let maxEach = max(style.minimumWingWidth, min(style.maximumWingWidth, maxCombined / 2))
        let wing = min(max(leftWidth, rightWidth), maxEach)
        let expandedLeft = max(geometry.screenFrame.minX, geometry.leftX - wing)
        let expandedRight = min(geometry.screenFrame.maxX, geometry.rightX + wing)
        let bottom = geometry.bottomY
        let expandedNotch = NotchGeometry(rect: CGRect(
            x: expandedLeft,
            y: bottom,
            width: max(1, expandedRight - expandedLeft),
            height: max(1, geometry.topY - bottom)
        ))
        let expanded = PhysicalBorderGeometry(
            screenFrame: geometry.screenFrame,
            notch: expandedNotch,
            leftX: expandedLeft,
            rightX: expandedRight,
            topY: geometry.topY,
            bottomY: bottom,
            cornerRadius: geometry.cornerRadius
        )
        let leftWing = CGRect(x: expandedLeft, y: geometry.notch.bottom, width: max(0, geometry.leftX - expandedLeft), height: geometry.notch.depth)
        let rightWing = CGRect(x: geometry.rightX, y: geometry.notch.bottom, width: max(0, expandedRight - geometry.rightX), height: geometry.notch.depth)
        return OverlayHoverLayout(
            collapsedGeometry: geometry,
            expandedGeometry: expanded,
            leftWingRect: leftWing,
            rightWingRect: rightWing,
            expandedHitRect: CGRect(
                x: expandedLeft,
                y: max(geometry.screenFrame.minY, bottom - 8),
                width: expandedRight - expandedLeft,
                height: geometry.topY - max(geometry.screenFrame.minY, bottom - 8)
            )
        )
    }

    private static func wingWidth(for strings: [String], style: NotchHoverStyle) -> CGFloat {
        let main = strings.first ?? ""
        let caption = strings.dropFirst().first ?? ""
        let mainWidth = (main as NSString).size(withAttributes: [.font: style.mainFont]).width
        let captionWidth = (caption as NSString).size(withAttributes: [.font: style.captionFont]).width
        return min(style.maximumWingWidth, max(style.minimumWingWidth, ceil(max(mainWidth, captionWidth) + style.horizontalInset * 4)))
    }
}
