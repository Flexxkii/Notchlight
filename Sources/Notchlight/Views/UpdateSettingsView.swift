import SwiftUI

struct UpdateSettingsView: View {
    @Bindable var controller: UpdateController

    var body: some View {
        GroupBox("Software updates") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Notchlight \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")")
                        .font(.subheadline)
                    Spacer()
                    Button("Check for Updates…", action: controller.checkForUpdates)
                        .disabled(!controller.canCheck)
                }
                Toggle("Automatically check for updates", isOn: $controller.automaticallyChecks)
                    .disabled(controller.unavailableReason != nil)
                Text(controller.unavailableReason ?? "View release notes before installing. Downloads are signature-verified, and your settings are preserved when Notchlight relaunches.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
        }
    }
}
