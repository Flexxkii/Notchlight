import Foundation

public struct WidgetSnapshotStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public static func appGroup(bundle: Bundle = .main) -> Self? {
        guard let identifier = bundle.object(forInfoDictionaryKey: "NotchlightAppGroup") as? String,
              !identifier.isEmpty,
              let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            return nil
        }
        return Self(directory: directory.appendingPathComponent("NotchlightWidgets", isDirectory: true))
    }

    public func read() -> WidgetSnapshot {
        guard let data = try? Data(contentsOf: url), data.count <= 64 * 1024,
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data),
              snapshot.version == WidgetSnapshot.currentVersion else {
            return WidgetSnapshot(connection: .unavailable)
        }
        return snapshot
    }

    public func write(_ snapshot: WidgetSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    public var url: URL { directory.appendingPathComponent("usage-v1.json") }
}
