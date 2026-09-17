import SwiftUI

/// Core Animation owns the pulse; SwiftUI only sends appearance/visibility changes.
struct BorderPreviewOutline: NSViewRepresentable {
    let color: Color
    let lineWidth: Double
    let outset: Double
    let start: Double
    let end: Double
    let isEnabled: Bool
    let glow: Bool
    let shouldPulse: Bool

    func makeNSView(context: Context) -> PreviewOutlineView { PreviewOutlineView() }

    func updateNSView(_ view: PreviewOutlineView, context: Context) {
        view.update(.init(color: NSColor(color), lineWidth: lineWidth, outset: outset,
                          start: start, end: end, isEnabled: isEnabled,
                          glow: glow, shouldPulse: shouldPulse))
    }

    static func dismantleNSView(_ view: PreviewOutlineView, coordinator: ()) {
        view.stopAnimating()
    }

    static func pulseAmount(at date: Date) -> Double {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
        return 0.5 - 0.5 * cos(phase * 2 * .pi)
    }
}
