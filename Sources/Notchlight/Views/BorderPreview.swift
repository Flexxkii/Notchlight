import SwiftUI
import BorderOverlay

struct BorderPreview: View {
    let model: BorderModel
    var isWindowVisible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var previewTitle: String {
        if model.codexLinked {
            guard let usage = model.selectedUsage else { return "Waiting for Codex usage" }
            return "\(model.codexUsageDisplay.formattedPercentage(for: usage)) \(usage.title.lowercased()) \(model.codexUsageDisplay.description)"
        }
        return "Meet your Mac’s new outline."
    }

    private var previewSubtitle: String {
        if model.isEnabled && model.showOnlyWhileWorking && !model.effectiveIsEnabled {
            return "WAITING FOR CODEX ACTIVITY"
        }
        if model.codexLinked {
            if model.codex.usageError != nil { return "LAST KNOWN USAGE" }
            if model.codex.isWorking { return "CODEX IS WORKING · GLOW ON" }
            return "CODEX USAGE"
        }
        return "APPEARANCE PREVIEW"
    }

    private var shouldPulse: Bool {
        isWindowVisible && model.effectivePulse && model.effectiveGlow && model.effectiveIsEnabled
            && model.effectiveEndPercentage > model.effectiveStartPercentage
            && !reduceMotion
    }

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [Color(red: 0.14, green: 0.22, blue: 0.25), Color(red: 0.07, green: 0.11, blue: 0.15)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Ellipse()
                .fill(Color(red: 0.21, green: 0.35, blue: 0.33).opacity(0.4))
                .frame(width: 470, height: 150)
                .rotationEffect(.degrees(-22))
                .offset(x: -70, y: 56)
                .blur(radius: 30)

            Rectangle()
                .fill(.black.opacity(0.16))
                .frame(height: 30)

            ZStack {
                PreviewNotchShape().fill(.black)
                if model.effectiveIsEnabled {
                    BorderStripMarkerView(style: model.stripStyle, outset: model.padding + model.lineWidth / 2)
                }
                BorderPreviewOutline(
                    color: model.effectiveBorderColor, lineWidth: model.lineWidth,
                    outset: model.padding + model.lineWidth / 2,
                    start: model.effectiveStartPercentage / 100,
                    end: model.effectiveEndPercentage / 100,
                    isEnabled: model.effectiveIsEnabled, glow: model.effectiveGlow,
                    shouldPulse: shouldPulse
                )
            }
                .frame(width: 156, height: 34)

            VStack(spacing: 6) {
                Spacer()
                Text(previewTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                Text(previewSubtitle)
                    .font(.caption.monospaced())
                    .tracking(0.5)
                    .foregroundStyle(.white.opacity(contrast == .increased ? 1 : 0.85))
            }
            .padding(.bottom, 20)
        }
        .frame(height: 140)
        .clipShape(.rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(contrast == .increased ? 0.6 : 0.10), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Appearance preview: camera notch, from \(model.effectiveStartPercentage.formatted()) to \(model.effectiveEndPercentage.formatted()) percent, \(model.lineWidth.formatted()) point border\(model.effectiveIsEnabled ? "" : ", hidden")\(model.codexLinked ? ", " + previewTitle : "")")
        .onAppear {
            model.diagnostics.updateContext(["preview_present": .bool(true), "preview_pulse_active": .bool(shouldPulse)])
        }
        .onChange(of: shouldPulse) { _, active in
            model.diagnostics.updateContext(["preview_pulse_active": .bool(active)])
        }
        .onDisappear {
            model.diagnostics.updateContext(["preview_present": .bool(false), "preview_pulse_active": .bool(false)])
        }
    }
}
