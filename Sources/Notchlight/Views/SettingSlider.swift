import SwiftUI

struct SettingSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(spacing: 9) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text("\(value.formatted(.number.precision(.fractionLength(1)))) pt")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step) {
                Text(title)
            }
            .labelsHidden()
            .controlSize(.small)
            .accessibilityValue("\(value.formatted()) points")
        }
    }
}
