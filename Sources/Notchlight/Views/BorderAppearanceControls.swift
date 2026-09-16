import SwiftUI

struct BorderAppearanceControls: View {
    @Bindable var model: BorderModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 17) {
                Toggle(isOn: $model.isEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Show border").font(.headline)
                        Text("Enable the notch border.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
                .accessibilityLabel("Show border")
                .accessibilityIdentifier("borderEnabledToggle")

                Toggle("Show only while Codex is working", isOn: $model.showOnlyWhileWorking)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.subheadline)
                    .accessibilityIdentifier("activityOnlyToggle")

                if model.showOnlyWhileWorking {
                    Picker("Hide after inactivity", selection: $model.inactivityTimeoutMinutes) {
                        Text("Immediately").tag(0.0)
                        ForEach(timeoutOptions, id: \.self) { minutes in
                            Text(minutes == 1 ? "1 minute" : "\(minutes.formatted()) minutes")
                                .tag(minutes)
                        }
                    }
                    .font(.subheadline)
                    .accessibilityIdentifier("inactivityTimeoutPicker")
                    Text(model.codexLinked
                         ? "The timeout starts when work stops. Click the notch any time to open settings."
                         : "Connect to Codex to show the border in this mode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SwipeSettingsControls(model: model)

                BorderColorControls(color: $model.borderColor)

                ColorPicker("Codex working color", selection: $model.workingColor, supportsOpacity: false)
                    .font(.subheadline)
                    .help("Used while Codex is actively working.")
                Text("Temporarily replaces the border color while Codex is working.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.codexLinked {
                    HStack {
                        Text("Line range").font(.subheadline)
                        Spacer()
                        Text(model.selectedUsage == nil ? "Waiting for usage" : "0–\(model.effectiveEndPercentage.formatted())%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text("Codex usage controls the end of the line. Disconnect above to set the range manually.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    PercentageSlider(title: "Start", value: $model.startPercentage)
                    PercentageSlider(title: "End", value: $model.endPercentage)

                    Text("0% starts at the top left. The line follows the notch to 100% at the top right.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()
                SettingSlider(title: "Line weight", value: $model.lineWidth, range: 1...6, step: 0.5)
                SettingSlider(title: "Notch spacing", value: $model.padding, range: 0...12, step: 0.5)
                Text("Moves the border and ticks together away from the notch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.codexLinked {
                    Label("Glow follows Codex activity", systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Toggle("Soft glow", isOn: $model.glow)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityIdentifier("softGlowToggle")
                }
            }
            .padding(12)
        }
    }

    private var timeoutOptions: [Double] {
        let presets: [Double] = [1, 5, 10, 30, 60]
        let selected = model.inactivityTimeoutMinutes
        return selected > 0 && !presets.contains(selected)
            ? (presets + [selected]).sorted()
            : presets
    }
}
