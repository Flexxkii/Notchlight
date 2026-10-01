import SwiftUI
import WidgetKit
import WidgetShared
import WidgetViews

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: .now, snapshot: WidgetSnapshot(connection: .loading))
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        // Preview never invents a live account allowance.
        completion(UsageEntry(date: .now, snapshot: read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let snapshot = read()
        let now = Date()
        let entries = snapshot.timelineDates(from: now).map { UsageEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
    }

    private func read() -> WidgetSnapshot {
        WidgetSnapshotStore.appGroup()?.read() ?? WidgetSnapshot(connection: .unavailable)
    }
}

struct UsageEntryView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        UsageWidgetView(snapshot: entry.snapshot, date: entry.date, medium: family == .systemMedium)
    }
}

@main
struct NotchlightWidgets: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.kind, provider: UsageProvider()) { entry in
            UsageEntryView(entry: entry)
        }
        .configurationDisplayName("Notchlight Usage")
        .description("Remaining Codex allowances and recently observed activity.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}
