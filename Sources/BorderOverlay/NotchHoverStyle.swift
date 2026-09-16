import AppKit

/// Shared sizing for text measurement, drawing, and the hover panel's bounds.
public struct NotchHoverStyle: Equatable, Sendable {
    public static let defaultTextSize = 12.0
    public static let textSizeRange = 10.0...14.0
    public let textSize: Double

    public init(textSize: Double = defaultTextSize) {
        self.textSize = textSize.isFinite
            ? min(max(textSize, Self.textSizeRange.lowerBound), Self.textSizeRange.upperBound)
            : Self.defaultTextSize
    }

    var mainFont: NSFont { .systemFont(ofSize: textSize, weight: .medium) }
    var captionFont: NSFont { .systemFont(ofSize: max(9, textSize * 10 / 14), weight: .regular) }
    var mainRowHeight: CGFloat { mainFont.pointSize + 4 }
    var captionRowHeight: CGFloat { captionFont.pointSize + 2 }
    var rowSpacing: CGFloat { 1 }
    var contentHeight: CGFloat { mainRowHeight + captionRowHeight + rowSpacing }
    var horizontalInset: CGFloat { 8 * textSize / 14 }
    var minimumWingWidth: CGFloat { 110 * textSize / 14 }
    var maximumWingWidth: CGFloat { 200 * textSize / 14 }
}
