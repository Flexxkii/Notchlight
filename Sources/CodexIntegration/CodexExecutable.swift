import Foundation

enum CodexExecutable {
    static func locate() -> URL? {
        var candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex").path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex").path,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex"
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        }
        return candidates.lazy.map { URL(fileURLWithPath: $0) }.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }
}
