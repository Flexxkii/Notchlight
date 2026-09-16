import CodexIntegration
import SwiftUI

struct CodexConnectionView: View {
    @Bindable var model: BorderModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: $model.codexLinked) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Connect to Codex").font(.headline)
                        Text("Usage sets the line. Activity turns on the glow.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
                .accessibilityLabel("Connect to Codex")
                .accessibilityIdentifier("codexConnectionToggle")

                if model.codexLinked {
                    HStack(alignment: .firstTextBaseline) {
                        if let usage = model.selectedUsage {
                            Text(model.codexUsageDisplay.formattedPercentage(for: usage))
                                .font(.title2.weight(.semibold).monospacedDigit())
                            Text("\(usage.title.lowercased()) \(model.codexUsageDisplay.description)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(model.codex.isRefreshing ? "Reading usage…" : "Usage unavailable")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Refresh", systemImage: "arrow.clockwise", action: model.codex.refresh)
                            .labelStyle(.iconOnly)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(model.codex.isRefreshing)
                            .help("Refresh Codex usage")
                    }

                    Picker("Usage window", selection: $model.codexWindow) {
                        ForEach(CodexUsageWindow.allCases) { window in
                            Text(window.title).tag(window)
                        }
                    }

                    Picker("Usage display", selection: $model.codexUsageDisplay) {
                        ForEach(CodexUsageDisplay.allCases) { display in
                            Text(display.title).tag(display)
                        }
                    }
                    .accessibilityIdentifier("codexUsageDisplayPicker")
                    .help("Show the percentage used or remaining in the border and usage details.")

                    HStack {
                        Label(
                            model.codex.activity?.isAvailable == true
                                ? (model.codex.isWorking ? "Codex is working · glow on" : "Codex is idle · glow off")
                                : "Activity unavailable · glow off",
                            systemImage: model.codex.isWorking ? "sparkles" : "circle.dashed"
                        )
                        .font(.caption)
                        .foregroundStyle(model.codex.isWorking ? Color.primary : Color.secondary)
                        Spacer(minLength: 0)
                    }

                    if let error = model.codex.usageError {
                        Text(model.selectedUsage == nil ? error : "Showing last known usage. \(error)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if let reset = model.selectedUsage?.resetsAt {
                        (Text("Resets ") + Text(reset, style: .relative))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if model.codex.usage != nil && model.selectedUsage == nil {
                        Text(model.codexWindow == .automatic
                             ? "Codex isn’t reporting usage limits for this account."
                             : "Codex isn’t reporting this window. Choose Automatic to use an available limit.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let activity = model.codex.activity, !activity.isAvailable {
                        Text(activity.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
        }
    }
}
