import Foundation
import CoreServices
import Darwin

struct ActivityWatchTargets: Sendable {
    var sessions: Set<String> = []
    var catalogs: Set<String> = []
}

struct ActivityWatchUpdate {
    var changes = ActivityFileChanges()
    var failed = false
}

struct ActivityFileChanges: Sendable {
    var paths: Set<String> = []
    var catalog = false
    var reconcile = false
    var restart = false

    var isEmpty: Bool { paths.isEmpty && !catalog && !reconcile && !restart }

    mutating func merge(_ other: Self) {
        paths.formUnion(other.paths)
        catalog = catalog || other.catalog
        reconcile = reconcile || other.reconcile
        restart = restart || other.restart
        if paths.count > 1_024 { paths.removeAll(); reconcile = true }
    }
}

@MainActor
protocol ActivityWatching: AnyObject {
    func start(_ receive: @escaping @Sendable (ActivityFileChanges) -> Void) -> Bool
    func stop()
    func updateTargets(_ targets: ActivityWatchTargets) -> ActivityWatchUpdate
}

extension ActivityWatching {
    func updateTargets(_ targets: ActivityWatchTargets) -> ActivityWatchUpdate { .init() }
}

/// Stream ownership is main-actor confined. The C callback owns only an immutable,
/// Sendable context; FSEvents retains it until the stream is invalidated/released.
@MainActor
final class ActivityFileWatcher: ActivityWatching {
    private let root: URL
    private let queue = DispatchQueue(label: "com.notchlight.activity-events", qos: .utility)
    private var stream: FSEventStreamRef?
    private var receive: (@Sendable (ActivityFileChanges) -> Void)?
    private enum FileKind: Sendable { case session, catalog, directory, sessionDirectory, ancestor }
    private struct FileWatch {
        let id: UUID
        let source: any DispatchSourceFileSystemObject
    }
    private var fileWatches: [String: FileWatch] = [:]
    private var directoryTargets: [String: FileKind] = [:]

    init(root: URL) { self.root = root }

    func start(_ receive: @escaping @Sendable (ActivityFileChanges) -> Void) -> Bool {
        stop()
        var existing = root
        var isDirectory: ObjCBool = false
        while !FileManager.default.fileExists(atPath: existing.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            let parent = existing.deletingLastPathComponent()
            guard parent.path != existing.path else { return false }
            existing = parent
        }
        let callback = Callback(root: root.path, receive: receive)
        var context = Self.makeContext(callback)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
            | kFSEventStreamCreateFlagNoDefer)
        let created = withExtendedLifetime(callback) {
            FSEventStreamCreate(nil, Self.eventCallback, &context, [existing.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25, flags)
        }
        guard let created else {
            return false
        }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        stream = created
        self.receive = receive
        directoryTargets = [existing.path: existing == root ? .directory : .ancestor]
        if existing == root { directoryTargets[root.appendingPathComponent("sqlite").path] = .directory }
        // At most 256 sessions and their parent directories, plus catalog roots.
        // Adjust only this process's soft limit, never the system or hard limit.
        var limits = rlimit()
        if getrlimit(RLIMIT_NOFILE, &limits) == 0, limits.rlim_cur < 1_024 {
            limits.rlim_cur = min(limits.rlim_max, 1_024)
            _ = setrlimit(RLIMIT_NOFILE, &limits)
        }
        if updateTargets(.init()).failed { stop(); return false }
        return true
    }

    func stop() {
        receive = nil
        for watch in fileWatches.values { watch.source.cancel() }
        fileWatches.removeAll()
        directoryTargets.removeAll()
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    isolated deinit { stop() }

    /// FSEvents may defer modifications until a long-lived writer closes its
    /// descriptor. Vnode sources deliver writes immediately, without polling.
    func updateTargets(_ targets: ActivityWatchTargets) -> ActivityWatchUpdate {
        guard stream != nil else { return ActivityWatchUpdate(failed: true) }
        var desired = directoryTargets
        for path in targets.sessions {
            desired[path] = .session
            desired[URL(fileURLWithPath: path, isDirectory: false).deletingLastPathComponent().path] = .sessionDirectory
        }
        for path in targets.catalogs { desired[path] = .catalog }
        for path in Set(fileWatches.keys).subtracting(desired.keys) {
            fileWatches.removeValue(forKey: path)?.source.cancel()
        }
        var result = ActivityWatchUpdate()
        for (path, kind) in desired where fileWatches[path] == nil {
            let descriptor = open(path, O_EVTONLY | O_CLOEXEC)
            guard descriptor >= 0 else {
                if errno != ENOENT && errno != ENOTDIR { result.failed = true }
                continue
            }
            let id = UUID()
            let source = Self.makeSource(descriptor: descriptor, queue: queue) { [weak self] detached in
                Task { @MainActor [weak self] in
                    guard let self, self.fileWatches[path]?.id == id else { return }
                    if detached { self.fileWatches.removeValue(forKey: path)?.source.cancel() }
                    switch kind {
                    case .session: self.receive?(ActivityFileChanges(paths: [path]))
                    case .catalog: self.receive?(ActivityFileChanges(catalog: true))
                    case .directory:
                        self.receive?(ActivityFileChanges(catalog: true, reconcile: detached, restart: detached))
                    case .sessionDirectory:
                        self.receive?(ActivityFileChanges(reconcile: true, restart: detached))
                    case .ancestor: self.receive?(ActivityFileChanges(reconcile: true, restart: true))
                    }
                }
            }
            fileWatches[path] = FileWatch(id: id, source: source)
            source.resume()
            // Re-read newly armed files to cover a write between the prior scan
            // and descriptor registration. Subsequent passes leave them alone.
            switch kind {
            case .session: result.changes.paths.insert(path)
            case .catalog, .directory, .sessionDirectory: result.changes.catalog = true
            case .ancestor: break
            }
        }
        return result
    }

    nonisolated private static func makeSource(descriptor: Int32, queue: DispatchQueue,
        changed: @escaping @Sendable (Bool) -> Void) -> any DispatchSourceFileSystemObject {
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke], queue: queue)
        source.setCancelHandler { close(descriptor) }
        source.setEventHandler { [weak source] in
            let flags = source?.data ?? []
            changed(!flags.intersection([.delete, .rename, .revoke]).isEmpty)
        }
        return source
    }

    nonisolated static func classify(path: String, flags: FSEventStreamEventFlags, root: String) -> ActivityFileChanges {
        let loss = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped)
        let rootChange = UInt32(kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagUnmount)
        if flags & rootChange != 0 { return ActivityFileChanges(reconcile: true, restart: true) }
        if flags & loss != 0 { return ActivityFileChanges(reconcile: true) }
        if root.hasPrefix(path + "/"), flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 {
            return ActivityFileChanges(reconcile: true, restart: true)
        }
        guard path == root || path.hasPrefix(root + "/") else { return ActivityFileChanges() }
        if path == root { return ActivityFileChanges(reconcile: true, restart: true) }
        let sessions = root + "/sessions"
        if path == sessions || path.hasPrefix(sessions + "/") {
            if flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 || path == sessions {
                return ActivityFileChanges(reconcile: true)
            }
            guard path.hasSuffix(".jsonl") else { return ActivityFileChanges() }
            return ActivityFileChanges(paths: [path])
        }
        let url = URL(fileURLWithPath: path, isDirectory: false)
        let directory = url.deletingLastPathComponent().path
        let name = url.lastPathComponent
        if directory == root || directory == root + "/sqlite" {
            if name.hasPrefix("state_") && (name.hasSuffix(".sqlite") || name.hasSuffix(".sqlite-wal")) {
                return ActivityFileChanges(catalog: true)
            }
            if path == root + "/sqlite" { return ActivityFileChanges(reconcile: true) }
        }
        return ActivityFileChanges()
    }

    // C invokes these callbacks on its delivery queue. Define them outside the
    // main-actor start method so Swift does not infer main-actor isolation.
    nonisolated private static var eventCallback: FSEventStreamCallback {
        { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let context = Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as! [String]
            var changes = ActivityFileChanges()
            for index in 0..<count {
                // FSEvents reports /private/var while Foundation normalizes the
                // same locations to /var. Match the reader's path representation.
                let path = URL(fileURLWithPath: paths[index], isDirectory: false).standardizedFileURL.path
                changes.merge(ActivityFileWatcher.classify(path: path, flags: eventFlags[index], root: context.root))
            }
            if !changes.isEmpty { context.receive(changes) }
        }
    }

    nonisolated private static func makeContext(_ callback: Callback) -> FSEventStreamContext {
        FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<Callback>.fromOpaque(pointer).retain()
                return pointer
            },
            release: { pointer in
                if let pointer { Unmanaged<Callback>.fromOpaque(pointer).release() }
            }, copyDescription: nil
        )
    }

    private final class Callback: Sendable {
        let root: String
        let receive: @Sendable (ActivityFileChanges) -> Void
        init(root: String, receive: @escaping @Sendable (ActivityFileChanges) -> Void) {
            self.root = root
            self.receive = receive
        }
    }
}
