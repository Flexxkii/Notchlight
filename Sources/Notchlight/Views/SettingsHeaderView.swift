import AppKit
import SwiftUI

struct SettingsHeaderView: View {
    // Resolve the shipping icon through macOS so the header stays in sync with
    // the Icon Composer asset and its compatibility renditions.
    private static let appIcon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: Self.appIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text("Notchlight")
                    .font(.title.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Your AI usage in a blink.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}
