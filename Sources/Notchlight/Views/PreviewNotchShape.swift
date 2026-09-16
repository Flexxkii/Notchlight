import SwiftUI

struct PreviewNotchShape: Shape {
    var outset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let rect = CGRect(x: rect.minX - outset, y: rect.minY,
                          width: rect.width + outset * 2, height: rect.height + outset)
        let radius = min(8 + outset, rect.height / 2)
        return Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + radius, y: rect.maxY),
                control: CGPoint(x: rect.minX, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.maxY - radius),
                control: CGPoint(x: rect.maxX, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
    }
}
