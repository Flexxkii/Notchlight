import SwiftUI

struct SignalSettingsView: View {
    @Bindable var model: BorderModel
    @State private var setup = SignalSetupController()

    var body: some View {
        GroupBox("Status signals") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Show when Codex needs attention", isOn: $model.attentionEnabled)
                    .accessibilityIdentifier("attentionToggle")
                Text("An amber border marks an explicit approval or input request. It clears when the turn resumes or ends, or after one hour.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.attentionEnabled {
                    Button("Set Up Codex Hooks…", action: setup.installHooks)
                        .disabled(setup.isBusy)
                    Text("Requires local Codex hooks and a one-time review in Codex using /hooks. Requests handled by automatic approval may appear briefly. Remote chats and unsupported tools may not report requests.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Toggle("Allow custom local signals", isOn: $model.customSignalsEnabled)
                    .accessibilityIdentifier("customSignalsToggle")
                Text("Let your own scripts show working, success, failure, or attention states. Signals temporarily replace the usage border and expire automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.customSignalsEnabled {
                    HStack {
                        Button("Install Command…", action: setup.installCommand)
                        Button("Copy Example", action: setup.copyExample)
                    }
                    Link("Command guide", destination: URL(string: "https://github.com/Flexxkii/notchlight/blob/main/docs/status-signals.md")!)
                        .font(.caption)
                }
                if let message = setup.message {
                    Label(message, systemImage: setup.failed ? "exclamationmark.triangle" : "info.circle")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let error = model.signals.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Retry", action: model.signals.retry)
                }
                ForEach(model.visibleSignals.prefix(8)) { signal in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(signal.message).font(.subheadline)
                            Text("\(signal.state.title) · \(signal.isCodex ? "Codex" : signal.source)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Dismiss") { model.signals.dismiss(signal) }
                            .accessibilityLabel("Dismiss \(signal.message)")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
        }
    }
}
