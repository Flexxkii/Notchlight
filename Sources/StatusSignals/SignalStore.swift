import Foundation
import Darwin

/// A bounded, same-user mailbox. Atomic replacement makes directory notifications
/// sufficient; no server, network port, authentication token, or polling is needed.
public struct SignalStore: Sendable {
    public let directory: URL
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Notchlight/Signals", isDirectory: true)
    }

    public init(directory: URL = Self.defaultDirectory) { self.directory = directory }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw SignalError.unsafeDirectory }
    }

    public func write(_ signal: StatusSignal) throws {
        guard signal.isValid(at: .now) else { throw SignalError.invalidSignal }
        try prepare()
        try withLock {
            let destination = directory.appendingPathComponent(signal.source + ".json")
            let files = try signalFiles()
            // Expired files do not accumulate indefinitely, even when the app is closed.
            for file in files where read(file, now: .now) == nil { try? FileManager.default.removeItem(at: file) }
            if !FileManager.default.fileExists(atPath: destination.path), try signalFiles().count >= 128 {
                throw SignalError.full
            }
            let data = try JSONEncoder().encode(signal)
            guard data.count <= 4096 else { throw SignalError.invalidSignal }
            let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
            let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
            try handle.write(contentsOf: data)
            try handle.close()
            guard rename(temporary.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
    }

    public func snapshot(now: Date = .now) throws -> [StatusSignal] {
        try prepare()
        return try signalFiles().prefix(128).compactMap { read($0, now: now) }.sorted {
            if $0.state.priority != $1.state.priority { return $0.state.priority > $1.state.priority }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.source < $1.source
        }
    }

    public func clear(source: String) throws {
        guard StatusSignal.validSource(source) else { throw SignalError.invalidSignal }
        try prepare()
        try withLock { try remove(source: source.lowercased()) }
    }

    private func remove(source: String) throws {
        let file = directory.appendingPathComponent(source + ".json")
        if unlink(file.path) != 0, errno != ENOENT { throw CocoaError(.fileWriteUnknown) }
    }

    public func clearCodex(session: String, turn: String? = nil) throws {
        try prepare()
        try withLock {
            for signal in try snapshot() where signal.codexSession == session && (turn == nil || signal.codexTurn == turn) {
                try remove(source: signal.source)
            }
        }
    }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        let descriptor = open(directory.appendingPathComponent(".lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw SignalError.unsafeDirectory }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              flock(descriptor, LOCK_EX) == 0 else { throw SignalError.unsafeDirectory }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func signalFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func read(_ url: URL, now: Date) -> StatusSignal? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_size <= 4096,
              let data = try? handle.read(upToCount: 4097), data.count <= 4096,
              let value = try? JSONDecoder().decode(StatusSignal.self, from: data),
              value.source + ".json" == url.lastPathComponent, value.isValid(at: now) else { return nil }
        return value
    }
}
