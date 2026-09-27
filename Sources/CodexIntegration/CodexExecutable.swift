import Foundation

enum CodexExecutable {
    static func locate(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        searchPath: String? = ProcessInfo.processInfo.environment["PATH"],
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        let applicationDirectories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeDirectory.appendingPathComponent("Applications", isDirectory: true)
        ]
        var candidates = applicationDirectories.flatMap { directory in
            ["ChatGPT.app", "Codex.app"].flatMap { app in
                // Prefer the packaged launcher so the CLI's internal bundle can move.
                ["codex-cli/bin/codex", "codex"].map { executable in
                    directory.appendingPathComponent("\(app)/Contents/Resources/\(executable)").path
                }
            }
        }
        candidates += [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex"
        ]
        if let searchPath {
            candidates.append(contentsOf: searchPath.split(separator: ":").map { "\($0)/codex" })
        }
        return candidates.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }
}
