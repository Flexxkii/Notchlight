import SwiftUI
import BorderOverlay

struct BorderStripMarkerShape: Shape {
    let length: Double
    let offset: Double
    let topPadding: Double
    let thickness: Double
    let outset: Double

    init(style: BorderStripStyle, outset: Double) {
        length = Double(style.length)
        offset = Double(style.offset)
        topPadding = Double(style.topPadding)
        thickness = Double(style.thickness)
        self.outset = outset
    }

    func path(in rect: CGRect) -> Path {
        let source = PreviewNotchShape(outset: outset).path(in: rect).cgPath
        let flipAxis = rect.minY + rect.maxY
        var flip = CGAffineTransform(translationX: 0, y: flipAxis).scaledBy(x: 1, y: -1)
        guard let contourPath = source.copy(using: &flip) else { return Path() }
        let segments = BorderStripGeometry.segments(
            for: contourPath,
            length: length,
            offset: offset,
            topPadding: topPadding,
            thickness: thickness,
            topEdgeY: Double(rect.maxY)
        )
        return Path { path in
            for segment in segments {
                path.move(to: CGPoint(x: segment.start.x, y: flipAxis - segment.start.y))
                path.addLine(to: CGPoint(x: segment.end.x, y: flipAxis - segment.end.y))
            }
        }
    }
}
