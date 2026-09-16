import BorderOverlay
import SwiftUI

struct HoverAppearanceControls: View {
    @Bindable var model: BorderModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                Text("Hover information")
                    .font(.headline)
                SettingSlider(
                    title: "Hover text size", value: $model.hoverTextSize,
                    range: NotchHoverStyle.textSizeRange, step: 0.5
                )
                Text("Size of the usage and reset information shown when you hover over the notch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
        }
    }
}
