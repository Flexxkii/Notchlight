import Foundation
import Darwin

/// Observes only auth-file metadata. No credentials or account identifiers are shared.
@MainActor
public final class CodexAccountChangeObserver {
    private let root: URL
    private var sources: [any DispatchSourceFileSystemObject] = []
    private var previous: String?
    private var receive: (() -> Void)?
    private var watchedDirectory: URL?

    public init(root: URL? = nil) {
        self.root = root ?? ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    public var revision: String {
        var info = stat()
        guard stat(root.appendingPathComponent("auth.json").path, &info) == 0 else { return "missing" }
        return "\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }

    public func start(_ receive: @escaping () -> Void) {
        stop()
        self.receive = receive
        previous = revision
        installSources()
    }

    public func stop() {
        for source in sources { source.cancel() }
        sources.removeAll()
        receive = nil
        watchedDirectory = nil
    }

    isolated deinit { stop() }

    private func installSources() {
        for source in sources { source.cancel() }
        sources.removeAll()
        var directory = root
        while !FileManager.default.fileExists(atPath: directory.path), directory.path != "/" {
            directory.deleteLastPathComponent()
        }
        watchedDirectory = directory
        for path in [directory, root.appendingPathComponent("auth.json")] {
            let descriptor = open(path.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .attrib, .extend, .revoke], queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in self?.check() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
    }

    private func check() {
        guard receive != nil else { return }
        let next = revision
        guard next != previous else {
            if watchedDirectory != root, FileManager.default.fileExists(atPath: root.path) { installSources() }
            return
        }
        previous = next
        installSources()
        receive?()
    }
}
