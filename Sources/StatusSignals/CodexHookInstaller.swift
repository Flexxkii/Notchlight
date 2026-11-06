import Foundation

public enum CodexHookInstaller {
    public static let marker = "Notchlight attention indicator"

    /// Merge only our entries. A dated backup is retained before every change.
    public static func install(executable: URL, codexHome: URL) throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let destination = codexHome.appendingPathComponent("hooks.json")
        var root: [String: Any] = [:]
        let previous: Data?
        if FileManager.default.fileExists(atPath: destination.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.intValue ?? .max <= 1_048_576 else { throw SignalError.unsafeDirectory }
            previous = try Data(contentsOf: destination)
            guard let decoded = try JSONSerialization.jsonObject(with: previous!) as? [String: Any] else {
                throw SignalError.invalidHook
            }
            root = decoded
        } else { previous = nil }
        if let value = root["hooks"], !(value is [String: Any]) { throw SignalError.invalidHook }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let command = "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "' codex-hook"
        for event in ["PermissionRequest", "PreToolUse", "PreModelRequest", "Stop", "Interrupt", "SessionEnd", "UserPromptSubmit"] {
            if let value = hooks[event], !(value is [[String: Any]]) { throw SignalError.invalidHook }
            var entries = hooks[event] as? [[String: Any]] ?? []
            // Remove only an entry we own in its entirety, never another hook
            // that happens to share a matcher or command prefix.
            entries.removeAll { entry in
                guard let handlers = entry["hooks"] as? [[String: Any]], handlers.count == 1 else { return false }
                return handlers.first?["statusMessage"] as? String == marker
            }
            var entry: [String: Any] = ["hooks": [["type": "command", "command": command,
                                                                  "timeout": 3, "statusMessage": marker]]]
            if event == "PreToolUse" { entry["matcher"] = "^(request_user_input|functions\\.request_user_input)$" }
            entries.append(entry)
            hooks[event] = entries
        }
        root["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        if data == previous { return destination }
        if let previous {
            let backup = codexHome.appendingPathComponent("hooks.notchlight-backup-\(UUID().uuidString).json")
            try previous.write(to: backup, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        // Refuse if someone edited the source while the candidate was prepared.
        if let previous, try Data(contentsOf: destination) != previous { throw CocoaError(.fileWriteFileExists) }
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
    }
}
