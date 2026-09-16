import SwiftUI
import BorderOverlay

struct StripAppearanceControls: View {
    @Bindable var model: BorderModel
    @State private var advancedIsExpanded = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 15) {
                Toggle(isOn: $model.stripsEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Show ruler ticks").font(.headline)
                        Text("Five markers cross the border at 0, 25, 50, 75, and 100%.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
                .accessibilityLabel("Show ruler ticks")
                .accessibilityIdentifier("stripEnabledToggle")

                HStack {
                    ColorPicker("Tick color", selection: $model.stripColor, supportsOpacity: false)
                        .font(.subheadline)
                        .accessibilityIdentifier("stripColorPicker")
                    Spacer(minLength: 12)
                    ForEach(BorderColorPreset.allCases) { preset in
                        Button { model.stripColor = preset.color } label: {
                            Circle()
                                .fill(preset.color)
                                .overlay { Circle().strokeBorder(.primary.opacity(0.5), lineWidth: 1) }
                                .frame(width: 16, height: 16)
                                .padding(3)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Use \(preset.rawValue) tick color")
                        .help("Use \(preset.rawValue) tick color")
                    }
                }

                SettingSlider(title: "Tick thickness", value: $model.stripThickness, range: 0.5...6, step: 0.5)
                SettingSlider(title: "Tick length", value: $model.stripLength, range: 2...20, step: 1)

                DisclosureGroup("Advanced tick placement", isExpanded: $advancedIsExpanded) {
                    VStack(alignment: .leading, spacing: 15) {
                        SettingSlider(title: "Outward offset", value: $model.stripOffset, range: 0...24, step: 1)
                        SettingSlider(title: "Top padding", value: $model.stripTopPadding, range: 0...12, step: 0.5)
                        VStack(spacing: 9) {
                            HStack {
                                Text("Opacity").font(.subheadline)
                                Spacer()
                                Text(model.stripOpacity.formatted(.percent.precision(.fractionLength(0))))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $model.stripOpacity, in: 0...1, step: 0.05) { Text("Tick opacity") }
                                .labelsHidden()
                                .controlSize(.small)
                                .accessibilityLabel("Tick opacity")
                                .accessibilityValue(model.stripOpacity.formatted(.percent.precision(.fractionLength(0))))
                        }
                    }
                    .padding(.top, 10)
                }
                .font(.subheadline)

                HStack {
                    Text("Ticks cross the border like ruler marks. They never glow.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset ticks", action: model.resetStrips)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(12)
        }
    }
}
