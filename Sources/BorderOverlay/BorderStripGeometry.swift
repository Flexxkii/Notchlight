import CoreGraphics
import Foundation

/// A single ruler-like marker crossing a contour. Coordinates use the same
/// y-up system as `CGPath` and AppKit. SwiftUI previews can flip the y axis
/// after consuming the points.
public struct BorderStripSegment: Equatable, Sendable {
    public let fraction: Double
    public let center: CGPoint
    public let start: CGPoint
    public let end: CGPoint
    public let outwardNormal: CGVector

    public init(fraction: Double, center: CGPoint, start: CGPoint, end: CGPoint, outwardNormal: CGVector) {
        self.fraction = fraction
        self.center = center
        self.start = start
        self.end = end
        self.outwardNormal = outwardNormal
    }
}

/// Converts a border path into percentage-positioned ruler markers. The
/// contour length and normals are calculated from the path itself, so these
/// positions agree with CAShapeLayer's `strokeStart` and `strokeEnd`.
public enum BorderStripGeometry {
    public static let standardFractions: [Double] = [0, 0.25, 0.5, 0.75, 1]

    public static func segments(
        for path: CGPath,
        fractions: [Double] = standardFractions,
        length: Double = 8,
        offset: Double = 0,
        topPadding: Double = 0,
        thickness: Double = 1.5,
        topEdgeY: Double? = nil
    ) -> [BorderStripSegment] {
        let normalizedLength = max(0, length.isFinite ? length : 8)
        let normalizedOffset = max(0, offset.isFinite ? offset : 0)
        let normalizedPadding = max(
            max(0, topPadding.isFinite ? topPadding : 0),
            max(0, thickness.isFinite ? thickness : 1.5) / 2
        )
        let contour = Contour(path: path)
        guard !contour.samples.isEmpty, contour.length > 0 else { return [] }

        var result: [BorderStripSegment] = []
        for rawFraction in fractions where rawFraction.isFinite {
            let fraction = min(max(rawFraction, 0), 1)
            if contour.isClosed, fraction >= 1 - 0.000_001,
               result.contains(where: { $0.fraction == 0 }) {
                continue
            }
            let point = contour.point(at: fraction)
            let normal = contour.outwardNormal(at: fraction)
            var center = CGPoint(
                x: point.x + normal.dx * normalizedOffset,
                y: point.y + normal.dy * normalizedOffset
            )
            if let topEdgeY, (fraction <= 0.000_001 || fraction >= 1 - 0.000_001), point.y >= topEdgeY - 0.000_001 {
                center.y -= normalizedPadding
            }
            let half = normalizedLength / 2
            let start = CGPoint(x: center.x - normal.dx * half, y: center.y - normal.dy * half)
            let end = CGPoint(x: center.x + normal.dx * half, y: center.y + normal.dy * half)
            result.append(BorderStripSegment(
                fraction: fraction,
                center: center,
                start: start,
                end: end,
                outwardNormal: normal
            ))
        }
        return result
    }
}

private struct Contour {
    struct Sample {
        let point: CGPoint
        let distance: CGFloat
        let tangent: CGVector
    }

    var samples: [Sample] = []
    var length: CGFloat = 0
    var isClosed = false
    var normalSign: CGFloat = 1

    init(path: CGPath) {
        var pieces: [(points: [CGPoint], closed: Bool)] = []
        var current: [CGPoint] = []
        var start = CGPoint.zero
        var last = CGPoint.zero

        path.applyWithBlock { element in
            let points = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint:
                if current.count > 1 { pieces.append((current, false)) }
                start = points[0]
                last = start
                current = [start]
            case .addLineToPoint:
                appendLine(from: last, to: points[0], into: &current)
                last = points[0]
            case .addQuadCurveToPoint:
                appendQuadratic(from: last, control: points[0], to: points[1], into: &current)
                last = points[1]
            case .addCurveToPoint:
                appendCubic(from: last, control1: points[0], control2: points[1], to: points[2], into: &current)
                last = points[2]
            case .closeSubpath:
                if distance(last, start) > 0.0001 { appendLine(from: last, to: start, into: &current) }
                if current.count > 1 { pieces.append((current, true)) }
                current = []
                last = start
            @unknown default:
                break
            }
        }
        if current.count > 1 { pieces.append((current, false)) }

        guard let chosen = pieces.max(by: { polylineLength($0.points) < polylineLength($1.points) }) else { return }
        isClosed = chosen.closed
        if isClosed {
            let shifted = Array(chosen.points.dropFirst()) + [chosen.points[0]]
            let area = zip(chosen.points, shifted).reduce(CGFloat.zero) {
                $0 + ($1.0.x * $1.1.y - $1.1.x * $1.0.y)
            }
            // A clockwise closed path in AppKit's y-up coordinates has its
            // exterior on the left; the open notch path uses the right side.
            normalSign = area < 0 ? -1 : 1
        }
        var cumulative: CGFloat = 0
        for index in chosen.points.indices {
            let point = chosen.points[index]
            let nextIndex = index + 1 < chosen.points.count ? index + 1 : (isClosed ? 0 : index)
            let next = chosen.points[nextIndex]
            let vector = CGVector(dx: next.x - point.x, dy: next.y - point.y)
            let segmentLength = hypot(vector.dx, vector.dy)
            let tangent = segmentLength > 0.000001
                ? CGVector(dx: vector.dx / segmentLength, dy: vector.dy / segmentLength)
                : CGVector(dx: 1, dy: 0)
            samples.append(Sample(point: point, distance: cumulative, tangent: tangent))
            cumulative += segmentLength
        }
        if !isClosed, let last = chosen.points.last {
            let prior = chosen.points.dropLast().last ?? last
            let vector = CGVector(dx: last.x - prior.x, dy: last.y - prior.y)
            let segmentLength = hypot(vector.dx, vector.dy)
            let tangent = segmentLength > 0.000001
                ? CGVector(dx: vector.dx / segmentLength, dy: vector.dy / segmentLength)
                : CGVector(dx: 1, dy: 0)
            samples.append(Sample(point: last, distance: cumulative, tangent: tangent))
        }
        length = cumulative
    }

    func point(at fraction: CGFloat) -> CGPoint {
        let target = min(max(fraction, 0), 1) * length
        guard let upper = samples.firstIndex(where: { $0.distance >= target }), upper > 0 else { return samples[0].point }
        let lower = upper - 1
        let a = samples[lower]
        let b = samples[upper]
        let span = max(0.000001, b.distance - a.distance)
        let t = (target - a.distance) / span
        return CGPoint(x: a.point.x + (b.point.x - a.point.x) * t, y: a.point.y + (b.point.y - a.point.y) * t)
    }

    func outwardNormal(at fraction: CGFloat) -> CGVector {
        let target = min(max(fraction, 0), 1) * length
        let sample = samples.last(where: { $0.distance <= target }) ?? samples[0]
        return CGVector(
            dx: normalSign * sample.tangent.dy,
            dy: normalSign * -sample.tangent.dx
        )
    }
}

private func appendLine(from start: CGPoint, to end: CGPoint, into points: inout [CGPoint]) {
    points.append(end)
}

private func appendQuadratic(from start: CGPoint, control: CGPoint, to end: CGPoint, into points: inout [CGPoint]) {
    for index in 1...32 {
        let t = CGFloat(index) / 32
        let one = 1 - t
        points.append(CGPoint(
            x: one * one * start.x + 2 * one * t * control.x + t * t * end.x,
            y: one * one * start.y + 2 * one * t * control.y + t * t * end.y
        ))
    }
}

private func appendCubic(from start: CGPoint, control1: CGPoint, control2: CGPoint, to end: CGPoint, into points: inout [CGPoint]) {
    for index in 1...64 {
        let t = CGFloat(index) / 64
        let one = 1 - t
        points.append(CGPoint(
            x: one * one * one * start.x + 3 * one * one * t * control1.x + 3 * one * t * t * control2.x + t * t * t * end.x,
            y: one * one * one * start.y + 3 * one * one * t * control1.y + 3 * one * t * t * control2.y + t * t * t * end.y
        ))
    }
}

private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat { hypot(lhs.x - rhs.x, lhs.y - rhs.y) }

private func polylineLength(_ points: [CGPoint]) -> CGFloat {
    zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
}
