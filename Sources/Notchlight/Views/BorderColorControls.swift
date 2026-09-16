import SwiftUI

struct BorderColorControls: View {
    @Binding var color: Color

    var body: some View {
        HStack {
            ColorPicker("Border color", selection: $color, supportsOpacity: false)
                .font(.subheadline)
                .accessibilityIdentifier("borderColorPicker")
            Spacer(minLength: 12)
            ForEach(BorderColorPreset.allCases) { preset in
                Button {
                    color = preset.color
                } label: {
                    Circle()
                        .fill(preset.color)
                        .overlay { Circle().strokeBorder(.primary.opacity(0.5), lineWidth: 1) }
                        .frame(width: 17, height: 17)
                        .padding(3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Use \(preset.rawValue) border")
                .help("Use \(preset.rawValue)")
            }
        }
    }
}
