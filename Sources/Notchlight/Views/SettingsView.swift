import SwiftUI

struct SettingsView: View {
    @Bindable var model: BorderModel
    var diagnostics: DiagnosticsController? = nil
    @State private var windowState = SettingsWindowState()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsHeaderView()

                BorderPreview(model: model, isWindowVisible: windowState.canAnimate)
                LaunchAtLoginSettingsView()
                CodexConnectionView(model: model)
                HoverAppearanceControls(model: model)
                BorderAppearanceControls(model: model)
                StripAppearanceControls(model: model)
                if let diagnostics {
                    DiagnosticsSettingsView(controller: diagnostics)
                }
                LegalSettingsView()

                HStack {
                    Label(model.statusLabel, systemImage: model.hasVisibleLine ? "checkmark.circle.fill" : "circle.dashed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset appearance", action: model.resetAppearance)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Text(model.targetDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 680)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 500, idealWidth: 500, maxWidth: .infinity,
               minHeight: 480, idealHeight: 820, maxHeight: .infinity)
        .background(SettingsWindowDiagnostics(recorder: model.diagnostics, state: windowState))
    }
}
