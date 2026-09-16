import SwiftUI

struct PercentageSlider: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                TextField(title, value: $value, format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .font(.caption.monospacedDigit())
                    .frame(width: 48)
                    .accessibilityLabel("\(title) percentage")
                Text("%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: 0...100) {
                Text(title)
            }
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel("\(title) percentage")
            .accessibilityValue("\(value.formatted()) percent")
        }
    }
}
