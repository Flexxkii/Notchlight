import SwiftUI
import BorderOverlay

struct BorderStripMarkerView: View {
    let style: BorderStripStyle
    var outset: Double = 0

    var body: some View {
        BorderStripMarkerShape(style: style, outset: outset)
            .stroke(Color(nsColor: style.color), style: StrokeStyle(lineWidth: style.thickness, lineCap: .butt))
            .opacity(style.isEnabled ? Double(style.opacity) : 0)
            .accessibilityHidden(true)
    }
}
