import Foundation
import Diagnostics

public enum CodexUsageWindow: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case fiveHour
    case weekly
    case monthly

    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .fiveHour: "5-hour"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        }
    }

    public var id: Self { self }
}

public struct CodexUsageValue: Sendable, Equatable {
    public let usedPercent: Double
    public let windowDurationMins: Int
    public let resetsAt: Date?
    /// Only set by a source that explicitly identifies calendar-month semantics.
    /// The current app-server duration-only schema cannot establish this.
    public let isCalendarMonth: Bool

    public init(usedPercent: Double, windowDurationMins: Int, resetsAt: Date?, isCalendarMonth: Bool = false) {
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
        self.isCalendarMonth = isCalendarMonth
    }

    public var title: String {
        if isCalendarMonth { return "Monthly" }
        switch windowDurationMins {
        case 300: return "5-hour"
        case 10_080: return "Weekly"
        case let minutes where minutes > 0 && minutes.isMultiple(of: 1_440):
            return "\(minutes / 1_440)-day"
        case let minutes where minutes > 0 && minutes.isMultiple(of: 60):
            return "\(minutes / 60)-hour"
        default: return "\(windowDurationMins)-minute"
        }
    }
}

public struct CodexUsageSnapshot: Sendable {
    public let windows: [CodexUsageValue]
    public let sampledAt: Date

    public init(windows: [CodexUsageValue], sampledAt: Date) {
        self.windows = windows
        self.sampledAt = sampledAt
    }

    public func value(for window: CodexUsageWindow) -> CodexUsageValue? {
        switch window {
        case .automatic:
            windows.first(where: { $0.windowDurationMins == 300 })
                ?? windows.first(where: { $0.windowDurationMins == 10_080 })
                ?? windows.first
        case .fiveHour:
            windows.first(where: { $0.windowDurationMins == 300 })
        case .weekly:
            windows.first(where: { $0.windowDurationMins == 10_080 })
        case .monthly:
            windows.first(where: \.isCalendarMonth)
        }
    }
}

public enum CodexUsageError: Error, LocalizedError, Sendable, Equatable {
    case executableUnavailable
    case launchFailed
    case timedOut
    case cancelled
    case invalidResponse
    case incompatibleAccount
    case signInRequired
    case protocolFailure

    public var errorDescription: String? {
        switch self {
        case .executableUnavailable: "Codex is not installed."
        case .launchFailed: "Codex could not be started."
        case .timedOut: "Codex usage information timed out."
        case .cancelled: "Codex usage request was cancelled."
        case .invalidResponse: "Codex returned invalid usage information."
        case .incompatibleAccount: "Codex usage is unavailable for this account."
        case .signInRequired: "Sign in to Codex to view usage."
        case .protocolFailure: "Codex usage information is unavailable."
        }
    }
}

enum CodexUsageParser {
    static func snapshot(from result: [String: Any], sampledAt: Date) throws -> CodexUsageSnapshot {
        let source: Any
        if let byID = result["rateLimitsByLimitId"] as? [String: Any],
           let codex = byID["codex"] {
            source = codex
        } else if let legacy = result["rateLimits"] {
            if let limits = legacy as? [String: Any],
               let limitID = limits["limitId"] as? String,
               limitID != "codex" {
                return CodexUsageSnapshot(windows: [], sampledAt: sampledAt)
            }
            source = legacy
        } else {
            return CodexUsageSnapshot(windows: [], sampledAt: sampledAt)
        }

        let values = collectValues(in: source)
        return CodexUsageSnapshot(windows: values, sampledAt: sampledAt)
    }

    private static func collectValues(in object: Any) -> [CodexUsageValue] {
        var found: [Int: CodexUsageValue] = [:]
        guard let dictionary = object as? [String: Any] else { return [] }
        for key in ["primary", "secondary"] {
            guard let window = dictionary[key] as? [String: Any], let parsed = parseValue(window) else { continue }
            found[parsed.windowDurationMins] = parsed
        }
        if let windows = dictionary["windows"] as? [[String: Any]] {
            for window in windows {
                guard let parsed = parseValue(window) else { continue }
                found[parsed.windowDurationMins] = parsed
            }
        }
        return found.values.sorted { $0.windowDurationMins < $1.windowDurationMins }
    }

    private static func parseValue(_ dictionary: [String: Any]) -> CodexUsageValue? {
        guard let used = number(dictionary["usedPercent"]), used.isFinite,
              let duration = integer(dictionary["windowDurationMins"]),
              duration > 0 else { return nil }
        let reset = date(dictionary["resetsAt"])
        return CodexUsageValue(usedPercent: min(max(used, 0), 100),
                               windowDurationMins: duration,
                               resetsAt: reset)
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return nil }
            return value.doubleValue
        }
        if let value = value as? Double { return value }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = number(value), number.isFinite else { return nil }
        return Int(exactly: number)
    }

    private static func date(_ value: Any?) -> Date? {
        if let seconds = number(value), seconds.isFinite { return Date(timeIntervalSince1970: seconds) }
        if let string = value as? String { return ISO8601DateFormatter().date(from: string) }
        return nil
    }
}

public actor CodexUsageReader {
    private let diagnostics: DiagnosticRecorder

    public init(diagnostics: DiagnosticRecorder = .disabled) {
        self.diagnostics = diagnostics
    }

    public func read() async throws -> CodexUsageSnapshot {
        try await readAccountAware().usage.get()
    }

    public func readAccountAware() async -> CodexUsageReadResult {
        let token = CodexCancellationToken()
        return await withTaskCancellationHandler(operation: {
            await Task.detached {
                let session = CodexRPCSession(cancellation: token, diagnostics: self.diagnostics)
                do {
                    let snapshot = try session.readSnapshot()
                    return CodexUsageReadResult(accountFingerprint: session.accountFingerprint, usage: .success(snapshot))
                } catch {
                    return CodexUsageReadResult(accountFingerprint: session.accountFingerprint,
                                               usage: .failure(error as? CodexUsageError ?? .protocolFailure))
                }
            }.value
        }, onCancel: { token.cancel() })
    }
}

final class CodexCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.withLock { value } }
    func cancel() { lock.withLock { value = true } }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }; return try body()
    }
}
