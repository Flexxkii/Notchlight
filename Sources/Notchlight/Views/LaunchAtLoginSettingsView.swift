import AppKit
import SwiftUI

struct LaunchAtLoginSettingsView: View {
    @State private var controller = LoginItemController()

    var body: some View {
        GroupBox("General") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Launch at login", isOn: $controller.isEnabled)
                    .toggleStyle(.checkbox)
                    .help("Start Notchlight automatically when you log in to your Mac.")

                Text("Start Notchlight automatically when you log in to your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if controller.requiresApproval {
                    Text("Allow Notchlight in System Settings → General → Login Items to enable launch at login.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Login Items…", action: controller.openSystemSettings)
                        .controlSize(.small)
                }

                if let error = controller.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
        }
        .onAppear(perform: controller.refreshStatus)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refreshStatus()
        }
    }
}
