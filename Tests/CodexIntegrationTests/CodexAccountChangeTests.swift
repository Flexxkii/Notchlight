import Foundation
import Testing
@testable import CodexIntegration

@MainActor
struct CodexAccountChangeTests {
    @Test func accountReplacementInvalidatesWithoutReadingCredentials() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let auth = directory.appendingPathComponent("auth.json")
        try Data("synthetic-first".utf8).write(to: auth)
        let observer = CodexAccountChangeObserver(root: directory)
        var changes = 0
        observer.start { changes += 1 }
        defer { observer.stop() }
        let before = observer.revision
        try Data("synthetic-second".utf8).write(to: auth, options: .atomic)
        for _ in 0..<50 where changes == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(changes >= 1)
        #expect(before != observer.revision)
        let afterReplace = changes
        try FileManager.default.removeItem(at: auth)
        for _ in 0..<50 where changes == afterReplace { try await Task.sleep(for: .milliseconds(10)) }
        #expect(changes > afterReplace)
        #expect(observer.revision == "missing")
        #expect(CodexAccountIdentity.fingerprint(["email": "synthetic-a@example.test"]) != CodexAccountIdentity.fingerprint(["email": "synthetic-b@example.test"]))
        #expect(CodexAccountIdentity.fingerprint([:]) == nil)
    }
}
