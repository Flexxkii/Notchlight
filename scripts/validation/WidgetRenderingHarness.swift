import AppKit
import SwiftUI
import WidgetKit
import WidgetShared
import WidgetViews

/// Synthetic fixtures only. This executable never writes the production app group.
@main
struct WidgetRenderingHarness {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let monthly = WidgetAllowance(usedPercent: 24, durationMinutes: 44_640,
            resetsAt: now.addingTimeInterval(12 * 86400 + 8 * 3600), isCalendarMonth: true)
        let dual = [WidgetAllowance(usedPercent: 48, durationMinutes: 300, resetsAt: now.addingTimeInterval(7920)),
                    WidgetAllowance(usedPercent: 24, durationMinutes: 10_080, resetsAt: now.addingTimeInterval(288000))]
        let monthlySnapshot = WidgetSnapshot(connection: .connected, allowances: [monthly], sampledAt: now,
            activity: .working, activitySampledAt: now)
        let dualSnapshot = WidgetSnapshot(connection: .connected, allowances: dual, sampledAt: now,
            activity: .working, activitySampledAt: now)
        for (name, scheme, mode) in [("dark", ColorScheme.dark, WidgetRenderingMode.fullColor),
                                      ("light", .light, .fullColor), ("vibrant", .dark, .vibrant),
                                      ("accented", .dark, .accented)] {
            let sheet = VStack(alignment: .leading, spacing: 18) {
                Text("Notchlight · synthetic widget fixtures · \(name)").font(.headline)
                HStack(spacing: 18) {
                    tile(monthlySnapshot, at: now, medium: false, scheme: scheme)
                    tile(dualSnapshot, at: now, medium: true, scheme: scheme)
                    tile(monthlySnapshot, at: now, medium: true, scheme: scheme)
                }
                HStack(spacing: 18) {
                    ForEach([WidgetConnection.loading, .disconnected, .signInRequired, .unavailable], id: \.rawValue) { state in
                        tile(WidgetSnapshot(connection: state, writtenAt: now), at: now, medium: false, scheme: scheme)
                    }
                }
                HStack(spacing: 18) {
                    tile(monthlySnapshot, at: now.addingTimeInterval(901), medium: false, scheme: scheme)
                    tile(WidgetSnapshot(connection: .connected, allowances: dual, sampledAt: now,
                         activity: .idle, activitySampledAt: now), at: now, medium: true, scheme: scheme)
                    tile(monthlySnapshot, at: now.addingTimeInterval(301), medium: false, scheme: scheme)
                }
            }
            .padding(24)
            .background(scheme == .dark ? Color.black : Color(white: 0.88))
            .environment(\.colorScheme, scheme)
            .environment(\.widgetRenderingMode, mode)
            let renderer = ImageRenderer(content: sheet)
            renderer.scale = 2
            guard let cgImage = renderer.cgImage,
                  let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try data.write(to: output.appendingPathComponent("\(name).png"))
        }
    }

    @MainActor static func tile(_ snapshot: WidgetSnapshot, at date: Date, medium: Bool, scheme: ColorScheme) -> some View {
        UsageWidgetView(snapshot: snapshot, date: date, medium: medium)
            .frame(width: medium ? 360 : 170, height: 170)
            .background(scheme == .dark ? Color(red: 0.075, green: 0.08, blue: 0.085) : Color(white: 0.97))
            .clipShape(RoundedRectangle(cornerRadius: 22))
    }
}
