import AppKit
import Observation
import StatusSignals

@MainActor @Observable
final class SignalSetupController {
    private(set) var message: String?
    private(set) var isBusy = false
    private(set) var failed = false

    private var helperURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/notchlight") }

    func installHooks() {
        guard !isBusy else { return }
        let helper = helperURL
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        isBusy = true
        Task {
            let result = await Task.detached(priority: .utility) {
                Result { try CodexHookInstaller.install(executable: helper, codexHome: home) }
            }.value
            isBusy = false
            switch result {
            case .success:
                failed = false
                message = "Hooks installed. In Codex, open /hooks and review the Notchlight hooks, then start a new chat. Existing hooks were preserved."
            case .failure(let error):
                failed = true
                message = "Couldn’t install hooks. \(error.localizedDescription)"
            }
        }
    }

    func installCommand() {
        do {
            guard FileManager.default.isExecutableFile(atPath: helperURL.path) else { throw CocoaError(.fileNoSuchFile) }
            let bin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let link = bin.appendingPathComponent("notchlight")
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), target == helperURL.path {
                // Already points to this installation.
            } else {
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: helperURL)
            }
            failed = false
            message = "Command installed at ~/.local/bin/notchlight. Use that path directly, or add ~/.local/bin to your shell’s PATH."
        } catch {
            failed = true
            message = "Couldn’t install the command. Existing files were preserved. \(error.localizedDescription)"
        }
    }

    func copyExample() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("~/.local/bin/notchlight signal --source build --state working --message 'Building…' --ttl 600", forType: .string)
    }
}
