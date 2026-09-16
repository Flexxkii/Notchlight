import SwiftUI

struct DiagnosticsSettingsView: View {
    @Bindable var controller: DiagnosticsController

    var body: some View {
        DisclosureGroup("Diagnostics") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Record performance diagnostics", isOn: $controller.recordingEnabled)
                Text(controller.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("CPU, memory, and app activity stay on this Mac. Export after your test cases to investigate resource usage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(controller.isExporting ? "Exporting…" : "Export diagnostics…") {
                        controller.chooseExportDestination()
                    }
                    .disabled(controller.isExporting)
                    Button("Reveal logs", action: controller.revealLogs)
                }
                if let error = controller.exportError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(.top, 8)
        }
    }
}
