import SwiftUI
import WidgetKit
import WidgetShared

struct AllowanceRingView: View {
    let allowance: WidgetAllowance
    let date: Date
    let diameter: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle().stroke(.primary.opacity(contrast == .increased ? 0.3 : 0.13), lineWidth: lineWidth)
                if let remaining = allowance.remaining, remaining > 0 {
                    Circle().trim(from: 0, to: remaining / 100)
                        .stroke(renderingMode == .fullColor ? Color.blue : Color.primary,
                                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .widgetAccentable()
                }
                VStack(spacing: 0) {
                    Text(allowance.percentage)
                        .font(.system(size: diameter * 0.29, weight: .semibold))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    Text(allowance.name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                }
                .padding(.horizontal, 10)
            }
            .padding(lineWidth / 2)
            .frame(width: diameter, height: diameter)
            Text(allowance.resetText(at: date))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.85)
        }
        .privacySensitive()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(allowance.accessibilityDescription(at: date))
    }

    private var lineWidth: CGFloat { max(5, diameter * 0.073) }
}
