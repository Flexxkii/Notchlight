import SwiftUI

struct PowerSettingsView: View {
    @Bindable var model: BorderModel

    var body: some View {
        GroupBox("Battery-aware effects") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Reduce effects on battery or in Low Power Mode", isOn: $model.batteryAwareEffects)
                    .accessibilityIdentifier("batteryAwareToggle")
                Text("Keep a static border, remove glow, and simplify notch transitions. Your colors and appearance settings are restored on external power when Low Power Mode is off.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.batteryAwareEffects {
                    Label(model.effectsReduced ? "Reduced effects are active" : "Full effects are active",
                          systemImage: model.effectsReduced ? "leaf" : "powerplug")
                        .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
        }
    }
}
