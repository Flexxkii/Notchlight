import Foundation

public enum WidgetConnection: String, Codable, Sendable {
    case connected, disconnected, signInRequired, loading, unavailable, stale
}

public enum WidgetActivity: String, Codable, Sendable {
    case working, idle, unavailable

    public var label: String {
        switch self {
        case .working: String(localized: "Working")
        case .idle: String(localized: "Idle")
        case .unavailable: String(localized: "Status unavailable")
        }
    }
}

public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let kind = "com.teodor.Notchlight.usage"
    public static let settingsURL = URL(string: "notchlight://usage")!
    public static let usageLifetime: TimeInterval = 15 * 60
    public static let activityLifetime: TimeInterval = 5 * 60

    public var version: Int = currentVersion
    public var connection: WidgetConnection
    public var allowances: [WidgetAllowance]
    public var selectedWindow: String
    public var sampledAt: Date?
    public var activity: WidgetActivity
    public var activitySampledAt: Date?
    public var writtenAt: Date

    public init(connection: WidgetConnection, allowances: [WidgetAllowance] = [],
                selectedWindow: String = "automatic", sampledAt: Date? = nil,
                activity: WidgetActivity = .unavailable, activitySampledAt: Date? = nil,
                writtenAt: Date = .now) {
        self.connection = connection
        self.allowances = allowances.filter(\.isValid)
        self.selectedWindow = selectedWindow
        self.sampledAt = sampledAt
        self.activity = activity
        self.activitySampledAt = activitySampledAt
        self.writtenAt = writtenAt
    }

    public func state(at date: Date) -> WidgetConnection {
        guard version == Self.currentVersion else { return .unavailable }
        switch connection {
        case .disconnected, .signInRequired: return connection
        case .loading:
            return Self.isFresh(writtenAt, at: date, lifetime: Self.usageLifetime) ? .loading : .unavailable
        case .unavailable: return .unavailable
        case .connected, .stale:
            guard !validAllowances.isEmpty else { return .unavailable }
            if connection == .stale || !Self.isFresh(sampledAt, at: date, lifetime: Self.usageLifetime)
                || validAllowances.contains(where: { $0.resetsAt.map { $0 <= date } == true }) {
                return .stale
            }
            return .connected
        }
    }

    public func currentActivity(at date: Date) -> WidgetActivity {
        guard state(at: date) == .connected,
              Self.isFresh(activitySampledAt, at: date, lifetime: Self.activityLifetime) else { return .unavailable }
        return activity
    }

    public func displayedAllowances(medium: Bool, at date: Date) -> [WidgetAllowance] {
        guard [.connected, .stale].contains(state(at: date)) else { return [] }
        let available = validAllowances
        if medium { return Array(available.prefix(2)) }
        let selected: WidgetAllowance? = switch selectedWindow {
        case "fiveHour": available.first { !$0.isCalendarMonth && $0.durationMinutes == 300 }
        case "weekly": available.first { !$0.isCalendarMonth && $0.durationMinutes == 10_080 }
        case "monthly": available.first { $0.isCalendarMonth }
        default: nil
        }
        return (selected ?? available.first).map { [$0] } ?? []
    }

    public func statusText(at date: Date) -> String {
        switch state(at: date) {
        case .connected: currentActivity(at: date).label
        case .stale: String(localized: "Stale · last known")
        case .disconnected: String(localized: "Disconnected")
        case .signInRequired: String(localized: "Sign in to Codex")
        case .loading: String(localized: "Loading usage")
        case .unavailable: String(localized: "Usage unavailable")
        }
    }

    public func detailText(at date: Date) -> String {
        switch state(at: date) {
        case .disconnected: String(localized: "Open Notchlight to connect")
        case .signInRequired: String(localized: "Sign in, then open Notchlight")
        case .loading: String(localized: "Waiting for Codex")
        default: String(localized: "Open Notchlight to refresh")
        }
    }

    /// Precomputed expiry entries prevent a cached Working label being authoritative forever.
    /// WidgetKit owns actual delivery times; this is not a real-time guarantee.
    public func timelineDates(from now: Date) -> [Date] {
        var dates = [now, now.addingTimeInterval(5 * 60), now.addingTimeInterval(15 * 60)]
        let boundaries = [sampledAt.map { $0.addingTimeInterval(Self.usageLifetime) },
                          activitySampledAt.map { $0.addingTimeInterval(Self.activityLifetime) }]
            + validAllowances.map(\.resetsAt)
        dates += boundaries.compactMap { $0 }.filter { $0 > now && $0 < now.addingTimeInterval(3600) }
        return Array(Set(dates)).sorted()
    }

    private var validAllowances: [WidgetAllowance] {
        var ids = Set<String>()
        return allowances.filter { $0.isValid && ids.insert($0.id).inserted }.sorted {
            func rank(_ value: WidgetAllowance) -> Int {
                if !value.isCalendarMonth && value.durationMinutes == 300 { return 0 }
                if !value.isCalendarMonth && value.durationMinutes == 10_080 { return 1 }
                if value.isCalendarMonth { return 2 }
                return 3
            }
            let left = rank($0), right = rank($1)
            return left == right ? $0.durationMinutes < $1.durationMinutes : left < right
        }
    }

    private static func isFresh(_ sample: Date?, at date: Date, lifetime: TimeInterval) -> Bool {
        guard let sample else { return false }
        let age = date.timeIntervalSince(sample)
        return age.isFinite && age >= -30 && age < lifetime
    }
}
