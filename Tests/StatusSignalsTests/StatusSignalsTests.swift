import Foundation
import Testing
@testable import StatusSignals

struct StatusSignalsTests {
    @Test func independentSourcesPriorityExpiryAndClear() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let now = Date()
        try store.write(StatusSignal(source: "build", state: .working, message: "Building", createdAt: now, lifetime: 10))
        try store.write(StatusSignal(source: "tests", state: .failure, message: "Tests failed", createdAt: now, lifetime: 20))
        #expect(try store.snapshot().map(\.source) == ["tests", "build"])
        try store.write(StatusSignal(source: "BUILD", state: .success, message: "Built", lifetime: 5))
        #expect(try store.snapshot().count == 2)
        #expect(try store.snapshot(now: now.addingTimeInterval(11)).map(\.source) == ["tests"])
        try store.clear(source: "TESTS")
        try store.clear(source: "tests")
        #expect(try store.snapshot().map(\.state) == [.success])
    }

    @Test func validationAndFilesystemBoundaries() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        for source in ["../escape", "a/b", "", "codex-forged", "CODEX-forged", String(repeating: "a", count: 81)] {
            #expect(throws: (any Error).self) { try StatusSignal(source: source, state: .attention, message: "No") }
        }
        for lifetime in [0.0, .infinity, .nan, 86_401] {
            #expect(throws: (any Error).self) { try StatusSignal(source: "build", state: .working, message: "No", lifetime: lifetime) }
        }
        #expect(throws: (any Error).self) { try StatusSignal(source: "build", state: .working, message: "Bad\ntext") }
        #expect(throws: (any Error).self) {
            try StatusSignal(source: "build", state: .working, message: "a" + String(repeating: "\u{0301}", count: 2048))
        }
        try store.prepare()
        try Data("not JSON".utf8).write(to: store.directory.appendingPathComponent("broken.json"))
        let outside = store.directory.appendingPathComponent("outside.txt")
        try JSONEncoder().encode(StatusSignal(source: "symlink", state: .failure, message: "Do not follow")).write(to: outside)
        try FileManager.default.createSymbolicLink(at: store.directory.appendingPathComponent("symlink.json"), withDestinationURL: outside)
        #expect(try store.snapshot().isEmpty)
        #expect(try Data(contentsOf: outside).count > 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: store.directory.path)
        #expect(throws: (any Error).self) { try store.snapshot() }
    }

    @Test func explicitHooksOnlyAndTurnIsolation() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        func send(_ event: String, session: String = "session", turn: String = "turn", tool: String = "Bash") throws {
            let input: [String: String] = ["session_id": session, "turn_id": turn, "hook_event_name": event,
                                          "tool_name": tool, "cwd": "/private/project", "tool_input": "secret command"]
            try JSONDecoder().decode(CodexAttentionHook.self, from: JSONSerialization.data(withJSONObject: input)).apply(to: store)
        }
        try send("PreToolUse")
        #expect(try store.snapshot().isEmpty)
        try send("PermissionRequest")
        try send("PreToolUse", turn: "second", tool: "request_user_input")
        try send("PermissionRequest", session: "other")
        #expect(try store.snapshot().count == 3)
        #expect(try store.snapshot().allSatisfy { $0.isCodex && $0.state == .attention })
        let persisted = try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        #expect(!persisted.contains("secret command"))
        #expect(!persisted.contains("/private/project"))
        try send("PostToolUse") // An unrelated completion cannot dismiss a request.
        #expect(try store.snapshot().count == 3)
        try send("PreModelRequest")
        #expect(try store.snapshot().count == 2)
        try send("Stop", turn: "second")
        #expect(try store.snapshot().count == 1)
        try send("SessionEnd", session: "other")
        #expect(try store.snapshot().isEmpty)
        try send("PreToolUse", tool: "request_user_input_async")
        #expect(try store.snapshot().isEmpty)
    }

    @Test func hookSetupPreservesExistingEntriesAndIsIdempotent() throws {
        let home = temporaryStore().directory
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let config = home.appendingPathComponent("hooks.json")
        let original = Data(#"{"description":"Keep me","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo existing"}]}]}}"#.utf8)
        try original.write(to: config)
        let executable = URL(fileURLWithPath: "/usr/bin/true")
        _ = try CodexHookInstaller.install(executable: executable, codexHome: home)
        let first = try Data(contentsOf: config)
        _ = try CodexHookInstaller.install(executable: executable, codexHome: home)
        #expect(try Data(contentsOf: config) == first)
        let text = String(decoding: first, as: UTF8.self)
        #expect(text.contains("echo existing"))
        #expect(text.contains("Keep me"))
        #expect(!text.contains("bypass"))
        let backups = try FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("backup") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: backups[0]) == original)
        let invalid = Data("invalid".utf8)
        try invalid.write(to: config)
        #expect(throws: (any Error).self) { try CodexHookInstaller.install(executable: executable, codexHome: home) }
        #expect(try Data(contentsOf: config) == invalid)
    }

    private func temporaryStore() -> SignalStore {
        SignalStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("notchlight-signals-\(UUID().uuidString)"))
    }
}
