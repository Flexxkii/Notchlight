import Foundation

/// The extension receives only display data, never Codex credentials or sessions.
public struct WidgetAllowance: Codable, Equatable, Sendable, Identifiable {
    public let usedPercent: Double
    public let durationMinutes: Int
    public let resetsAt: Date?
    public let isCalendarMonth: Bool

    public init(usedPercent: Double, durationMinutes: Int, resetsAt: Date?, isCalendarMonth: Bool = false) {
        self.usedPercent = usedPercent
        self.durationMinutes = durationMinutes
        self.resetsAt = resetsAt
        self.isCalendarMonth = isCalendarMonth
    }

    public var id: String { isCalendarMonth ? "calendarMonth" : "duration-\(durationMinutes)" }
    public var isValid: Bool { usedPercent.isFinite && durationMinutes > 0 }
    public var remaining: Double? { isValid ? 100 - min(100, max(0, usedPercent)) : nil }
    public var percentage: String {
        guard let remaining else { return "—" }
        return (remaining / 100).formatted(.percent.precision(.fractionLength(0...1)))
    }

    public var name: String {
        if isCalendarMonth { return String(localized: "Monthly") }
        switch durationMinutes {
        case 300: return String(localized: "5-hour")
        case 10_080: return String(localized: "Weekly")
        case let minutes where minutes.isMultiple(of: 1_440):
            return String(localized: "\(minutes / 1_440)-day")
        case let minutes where minutes.isMultiple(of: 60):
            return String(localized: "\(minutes / 60)-hour")
        default: return String(localized: "\(durationMinutes)-minute")
        }
    }

    public func resetText(at date: Date) -> String {
        guard let resetsAt, resetsAt.timeIntervalSince1970.isFinite else {
            return String(localized: "Reset unavailable")
        }
        let seconds = resetsAt.timeIntervalSince(date)
        guard seconds > 0 else { return String(localized: "Awaiting update") }
        if seconds < 60 { return String(localized: "Resets in <1m") }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
        guard let interval = formatter.string(from: seconds) else { return String(localized: "Reset unavailable") }
        return String(localized: "Resets in \(interval)")
    }

    public func accessibilityDescription(at date: Date) -> String {
        String(localized: "\(name), \(percentage) remaining. \(resetText(at: date)).")
    }
}
