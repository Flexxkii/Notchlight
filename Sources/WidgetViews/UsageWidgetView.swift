import AppKit
import SwiftUI
import WidgetKit
import WidgetShared

public struct UsageWidgetView: View {
    public let snapshot: WidgetSnapshot
    public let date: Date
    public let medium: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.widgetRenderingMode) private var renderingMode

    public init(snapshot: WidgetSnapshot, date: Date, medium: Bool) {
        self.snapshot = snapshot
        self.date = date
        self.medium = medium
    }

    public var body: some View {
        GeometryReader { geometry in
            let allowances = snapshot.displayedAllowances(medium: medium, at: date)
            VStack(spacing: 4) {
                header
                if allowances.isEmpty {
                    unavailable
                } else {
                    Text("Remaining")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    HStack(spacing: 12) {
                        ForEach(Array(allowances.enumerated()), id: \.element.id) { index, allowance in
                            if index > 0 {
                                Rectangle().fill(.primary.opacity(contrast == .increased ? 0.5 : 0.12))
                                    .frame(width: 1, height: 62).accessibilityHidden(true)
                            }
                            AllowanceRingView(allowance: allowance, date: date,
                                diameter: max(52, min(medium ? 108 : 98, geometry.size.height - (medium ? 49 : 66))))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    if !medium { status }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(12)
        .containerBackground(for: .widget) { background }
        .widgetURL(WidgetSnapshot.settingsURL)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notchlight usage")
    }

    public var background: some View {
        // Opaque content surface also works with Reduce Transparency; no glass or blur.
        (colorScheme == .dark ? Color(red: 0.075, green: 0.08, blue: 0.085) : Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 5) {
            if let icon = Self.icon {
                Image(nsImage: icon).resizable().scaledToFit().frame(width: 16, height: 16)
                    .accessibilityHidden(true)
            }
            Text("Notchlight").font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 4)
            if medium { status }
        }
    }

    private var status: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(snapshot.currentActivity(at: date) == .working && renderingMode == .fullColor ? Color.green : Color.secondary)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
            Text(snapshot.statusText(at: date))
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.9)
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.statusText(at: date))
    }

    private var unavailable: some View {
        VStack(spacing: 7) {
            Spacer(minLength: 0)
            Image(systemName: "chart.pie").font(.title2).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(snapshot.statusText(at: date)).font(.caption.weight(.semibold)).multilineTextAlignment(.center)
            Text(snapshot.detailText(at: date)).font(.caption2).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private static let icon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "Notchlight", withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }()
}
