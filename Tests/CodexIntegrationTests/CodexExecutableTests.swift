import Foundation
import Testing
@testable import CodexIntegration

struct CodexExecutableTests {
    private let home = URL(fileURLWithPath: "/Users/test user", isDirectory: true)

    @Test("Finds current and legacy desktop CLI layouts", arguments: [
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
        "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
        "/Users/test user/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
        "/Users/test user/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
        "/Users/test user/Applications/ChatGPT.app/Contents/Resources/codex",
        "/Users/test user/Applications/Codex.app/Contents/Resources/codex"
    ])
    func desktopLayouts(executable: String) {
        let result = CodexExecutable.locate(homeDirectory: home, searchPath: nil) { $0 == executable }
        #expect(result?.path == executable)
    }

    @Test("Prefers the packaged launcher over the old layout and standalone CLI")
    func launcherPreference() {
        let launcher = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"
        let available = Set([launcher, "/Applications/ChatGPT.app/Contents/Resources/codex", "/opt/homebrew/bin/codex"])
        let result = CodexExecutable.locate(homeDirectory: home, searchPath: nil, isExecutable: available.contains)
        #expect(result?.path == launcher)
    }

    @Test("Retains standalone CLI discovery", arguments: [
        "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/usr/bin/codex"
    ])
    func standalone(executable: String) {
        let result = CodexExecutable.locate(homeDirectory: home, searchPath: nil) { $0 == executable }
        #expect(result?.path == executable)
    }

    @Test("Skips unavailable candidates and finds an executable on PATH")
    func searchPathFallback() {
        let executable = "/Users/test user/tools/codex"
        let result = CodexExecutable.locate(homeDirectory: home, searchPath: ":/unavailable:/Users/test user/tools:") {
            $0 == executable
        }
        #expect(result?.path == executable)
    }

    @Test("Does not return a candidate without an executable")
    func unavailable() {
        #expect(CodexExecutable.locate(homeDirectory: home, searchPath: "/missing") { _ in false } == nil)
    }
}
