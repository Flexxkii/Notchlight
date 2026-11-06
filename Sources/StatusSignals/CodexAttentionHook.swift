import CryptoKit
import Foundation

public struct CodexAttentionHook: Decodable, Sendable {
    public let sessionID: String
    public let turnID: String?
    public let event: String
    public let tool: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", turnID = "turn_id", event = "hook_event_name", tool = "tool_name"
    }

    public func apply(to store: SignalStore, now: Date = .now) throws {
        guard !sessionID.isEmpty, sessionID.count <= 256 else { throw SignalError.invalidHook }
        let session = Self.digest(sessionID)
        switch event {
        case "PermissionRequest", "PreToolUse":
            let asksForInput = tool == "request_user_input" || tool == "functions.request_user_input"
            guard event == "PermissionRequest" || asksForInput else { return }
            guard let turnID, !turnID.isEmpty, turnID.count <= 256 else { throw SignalError.invalidHook }
            let turn = Self.digest(turnID)
            // One explicit request marker per turn. It stays until the model
            // resumes or the turn stops; unrelated tools cannot clear it.
            try store.write(StatusSignal(source: "codex-" + Self.digest(session + turn), state: .attention,
                                         message: asksForInput ? "Codex requested your input" : "Codex requested approval",
                                         createdAt: now, lifetime: 3_600, codexSession: session, codexTurn: turn))
        case "PreModelRequest", "Stop":
            if let turnID, !turnID.isEmpty { try store.clearCodex(session: session, turn: Self.digest(turnID)) }
        case "SessionStart", "SessionEnd", "UserPromptSubmit", "Interrupt":
            try store.clearCodex(session: session)
        default: break
        }
    }

    private static func digest(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
