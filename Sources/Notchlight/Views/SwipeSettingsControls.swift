import AppKit
import SwiftUI

struct SwipeSettingsControls: View {
    @Bindable var model: BorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Hide when swiping", isOn: $model.hideWhenSwiping)
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityIdentifier("hideWhenSwipingToggle")
                .help("Temporarily hides the border at the start of a desktop swipe and eases it back after the swipe finishes or is canceled.")

            if model.hideWhenSwiping {
                statusView
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        Group {
            switch model.swipeMonitoringStatus {
            case .disabled:
                Text("Swipe monitoring is off.")
            case .monitoring:
                Text("Swipe monitoring is enabled.")
            case .permissionRequired:
                VStack(alignment: .leading, spacing: 7) {
                    Text("Input Monitoring permission is needed to hide during desktop swipes.")
                    Button("Allow Input Monitoring") {
                        model.requestSwipeMonitoringPermission()
                    }
                    Button("Open Input Monitoring Settings") {
                        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else { return }
                        NSWorkspace.shared.open(url)
                    }
                }
            case .unavailable:
                HStack {
                    Text("Swipe monitoring is unavailable; using standard desktop transitions.")
                    Spacer()
                    Button("Retry") { model.refreshSwipeMonitoring() }
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
