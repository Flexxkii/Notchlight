import SwiftUI

/// Only the glowing stroke depends on time; the backdrop, labels, and ticks stay outside this timeline.
struct BorderPreviewOutline: View {
    let color: Color
    let lineWidth: Double
    let outset: Double
    let start: Double
    let end: Double
    let isEnabled: Bool
    let glow: Bool
    let shouldPulse: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !shouldPulse)) { timeline in
            let pulse = shouldPulse ? Self.pulseAmount(at: timeline.date) : 0
            PreviewNotchShape(outset: outset)
                .trim(from: start, to: end)
                .stroke(color.opacity(isEnabled && end > start ? 1 : 0),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .shadow(color: glow && isEnabled
                            ? color.opacity(shouldPulse ? 0.25 + 0.75 * pulse : 0.85)
                            : .clear,
                        radius: shouldPulse ? 3 + 9 * pulse : 8)
        }
        .accessibilityHidden(true)
    }

    static func pulseAmount(at date: Date) -> Double {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
        return 0.5 - 0.5 * cos(phase * 2 * .pi)
    }
}
