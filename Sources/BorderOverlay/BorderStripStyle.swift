import AppKit

/// Appearance and placement for the five percentage markers drawn across the
/// border contour. Values are normalized at construction time so renderers can
/// use the style without repeating preference validation.
public struct BorderStripStyle {
    public let isEnabled: Bool
    public let thickness: CGFloat
    public let length: CGFloat
    public let offset: CGFloat
    public let topPadding: CGFloat
    public let color: NSColor
    public let opacity: CGFloat

    public init(
        isEnabled: Bool = true,
        thickness: Double = 1.5,
        length: Double = 8,
        offset: Double = 0,
        topPadding: Double = 2,
        color: NSColor = .white,
        opacity: Double = 0.7
    ) {
        self.isEnabled = isEnabled
        self.thickness = BorderStripStyle.normalizedThickness(CGFloat(thickness))
        self.length = BorderStripStyle.normalizedLength(CGFloat(length))
        self.offset = BorderStripStyle.normalizedOffset(CGFloat(offset))
        self.topPadding = BorderStripStyle.normalizedTopPadding(CGFloat(topPadding))
        self.color = color.usingColorSpace(.sRGB) ?? color
        self.opacity = BorderStripStyle.normalizedOpacity(CGFloat(opacity))
    }

    static func normalizedThickness(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 1.5 }
        return min(max(value, 0.5), 6)
    }

    static func normalizedLength(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 8 }
        return min(max(value, 2), 20)
    }

    static func normalizedOffset(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 24)
    }

    static func normalizedTopPadding(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 2 }
        return min(max(value, 0), 12)
    }

    static func normalizedOpacity(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0.7 }
        return min(max(value, 0), 1)
    }
}
