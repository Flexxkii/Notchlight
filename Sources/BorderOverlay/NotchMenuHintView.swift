import SwiftUI

struct NotchMenuHintView: View {
    let dismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var animateArrow = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.up")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(6)
                .background(.background, in: Circle())
                .offset(y: animateArrow && !reduceMotion ? -4 : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.65).repeatCount(6, autoreverses: true),
                           value: animateArrow)
                .accessibilityHidden(true)

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Click your notch")
                        .font(.headline)
                    Text("to open the Notchlight menu.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

                Button("Dismiss hint", systemImage: "xmark", action: dismiss)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(3)
                    .help("Dismiss hint")
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(reduceTransparency ? AnyShapeStyle(.background) : AnyShapeStyle(.regularMaterial))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.primary.opacity(contrast == .increased ? 0.6 : 0.15), lineWidth: 1)
            }
        }
        .fixedSize()
        .padding(8)
        .onAppear { animateArrow = !reduceMotion }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { animateArrow = false }
        }
    }
}
