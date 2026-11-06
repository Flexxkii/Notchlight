import Foundation

public struct StatusSignal: Codable, Equatable, Sendable, Identifiable {
    public enum State: String, Codable, CaseIterable, Sendable {
        case working, success, failure, attention

        public var title: String {
            switch self {
            case .working: "Working"
            case .success: "Succeeded"
            case .failure: "Failed"
            case .attention: "Needs attention"
            }
        }

        public var priority: Int {
            switch self {
            case .attention: 4
            case .failure: 3
            case .working: 2
            case .success: 1
            }
        }
    }

    public let version: Int
    public let source: String
    public let state: State
    public let message: String
    public let createdAt: Date
    public let expiresAt: Date
    /// Opaque correlation keys only. Never contains prompts, commands, or paths.
    public let codexSession: String?
    public let codexTurn: String?
    public var id: String { source }
    public var isCodex: Bool { codexSession != nil }

    public init(source: String, state: State, message: String, createdAt: Date = .now,
                lifetime: TimeInterval = 300, codexSession: String? = nil, codexTurn: String? = nil) throws {
        guard Self.validSource(source), !message.isEmpty, message.count <= 120, message.utf8.count <= 1024,
              !message.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              lifetime.isFinite, (1...86_400).contains(lifetime),
              createdAt.timeIntervalSince1970.isFinite,
              (codexSession == nil) == (codexTurn == nil),
              (codexSession == nil) == !source.lowercased().hasPrefix("codex-") else { throw SignalError.invalidSignal }
        version = 1
        self.source = source.lowercased()
        self.state = state
        self.message = message
        self.createdAt = createdAt
        expiresAt = createdAt.addingTimeInterval(lifetime)
        self.codexSession = codexSession
        self.codexTurn = codexTurn
    }

    public static func validSource(_ source: String) -> Bool {
        !source.isEmpty && source.utf8.count <= 80
            && source.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }

    public func isValid(at now: Date) -> Bool {
        version == 1 && Self.validSource(source) && source == source.lowercased()
            && !message.isEmpty && message.count <= 120 && message.utf8.count <= 1024
            && !message.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && createdAt <= now.addingTimeInterval(5) && expiresAt > now
            && (1...86_400).contains(expiresAt.timeIntervalSince(createdAt))
            && (codexSession == nil) == (codexTurn == nil)
            && (codexSession == nil) == !source.hasPrefix("codex-")
    }
}

public enum SignalError: Error, LocalizedError {
    case invalidSignal, unsafeDirectory, full, invalidHook

    public var errorDescription: String? {
        switch self {
        case .invalidSignal: "Use a source containing only letters, numbers, hyphens or underscores, a message of 1–120 characters, and a lifetime of 1–86400 seconds. The codex- prefix is reserved."
        case .unsafeDirectory: "The signal folder must be a private folder owned by your account, not a symbolic link."
        case .full: "The signal folder is full. Clear an existing source before adding another."
        case .invalidHook: "The Codex hook event is missing its session or turn identifier."
        }
    }
}
