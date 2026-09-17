import Foundation
import SQLite3
import Darwin
import Diagnostics
#if canImport(AppKit)
import AppKit
#endif

public struct CodexActivitySnapshot: Sendable, Equatable {
    public let isWorking: Bool
    public let activeTaskCount: Int
    public let isAvailable: Bool
    public let detail: String
    public let sampledAt: Date

    public init(isWorking: Bool, activeTaskCount: Int, isAvailable: Bool, detail: String, sampledAt: Date) {
        self.isWorking = isWorking
        self.activeTaskCount = activeTaskCount
        self.isAvailable = isAvailable
        self.detail = detail
        self.sampledAt = sampledAt
    }
}

/// Reads only local Codex lifecycle metadata. Conversation text is never retained or returned.
public actor CodexActivityReader {
    private let diagnostics: DiagnosticRecorder
    private let desktopLaunchDateProvider: @Sendable () async -> Date?
    nonisolated let codexHome: URL
    private let sessionRoot: URL
    private var filesByPath: [String: ActivityFileState] = [:]
    private var rolloutPaths: [URL] = []
    private var desktopLaunchDate: Date?
    private var sourceAvailable = false
    private var catalogAvailable = false
    private var catalogWatchPaths: Set<String> = []
    private var unreadablePaths: Set<String> = []
    private var sampledBytesRead = 0
    private var sampledChangedFiles = 0
    private var sampledMetadataChecks = 0
    private var sampledParsedRecords = 0
    private var sampledUnreadableFiles = 0
    private var sampledParseFailures = 0

    private let activeWindow: TimeInterval = 15 * 60
    private let maxTailBytes = 8 * 1024 * 1024
    private let maxCachedFiles = 256

    public init(diagnostics: DiagnosticRecorder = .disabled,
                codexHome: URL? = nil,
                desktopLaunchDateProvider: (@Sendable () async -> Date?)? = nil) {
        self.diagnostics = diagnostics
        self.desktopLaunchDateProvider = desktopLaunchDateProvider ?? {
            #if canImport(AppKit)
            await MainActor.run {
                let bundleIDs = ["com.openai.codex", "com.openai.chatgpt"]
                return NSWorkspace.shared.runningApplications.first { application in
                    guard let bundleID = application.bundleIdentifier else { return false }
                    return bundleIDs.contains(bundleID)
                }?.launchDate
            }
            #else
            return nil
            #endif
        }
        let home = codexHome ?? ProcessInfo.processInfo.environment["CODEX_HOME"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        self.codexHome = home.standardizedFileURL.resolvingSymlinksInPath()
        self.sessionRoot = self.codexHome.appendingPathComponent("sessions", isDirectory: true)
    }

    /// An explicit reconciliation. Continuous consumers should use CodexActivityObservation.
    public func read() async -> CodexActivitySnapshot {
        let launch = await currentDesktopLaunchDate()
        return refresh(paths: nil, refreshCatalog: true, launchDate: launch, reason: "explicit").snapshot
    }

    func currentDesktopLaunchDate() async -> Date? { await desktopLaunchDateProvider() }

    /// Runs entirely on the reader actor; no suspension can interleave cache mutations.
    func refresh(paths: Set<String>?, refreshCatalog: Bool, launchDate: Date?,
                 reason: String, now: Date = Date()) -> ActivityRefresh {
        sampledBytesRead = 0
        sampledChangedFiles = 0
        sampledMetadataChecks = 0
        sampledParsedRecords = 0
        sampledUnreadableFiles = 0
        sampledParseFailures = 0
        let interval = diagnostics.beginInterval(.activityRead)
        var outcome: DiagnosticOutcome = .success
        defer {
            diagnostics.endInterval(interval, outcome: outcome, fields: [
                "reason": .string(reason),
                "rolloutPaths": .int(Int64(rolloutPaths.count)),
                "cachedFiles": .int(Int64(filesByPath.count)),
                "metadataChecks": .int(Int64(sampledMetadataChecks)),
                "changedFiles": .int(Int64(sampledChangedFiles)),
                "bytesRead": .int(Int64(sampledBytesRead)),
                "parsedRecords": .int(Int64(sampledParsedRecords)),
                "unreadableFiles": .int(Int64(sampledUnreadableFiles)),
                "parseFailures": .int(Int64(sampledParseFailures))
            ])
        }
        if Task.isCancelled { outcome = .cancelled; return ActivityRefresh(snapshot: unavailable(at: now)) }
        guard let launchDate else {
            desktopLaunchDate = nil
            filesByPath.removeAll()
            rolloutPaths.removeAll()
            sourceAvailable = true
            catalogAvailable = false
            unreadablePaths.removeAll()
            catalogWatchPaths.removeAll()
            return ActivityRefresh(snapshot: idle(at: now), watchTargets: .init())
        }
        let restarted = launchDate != desktopLaunchDate
        if restarted {
            desktopLaunchDate = launchDate
            filesByPath.removeAll()
            unreadablePaths.removeAll()
        }
        var selected = paths ?? Set(rolloutPaths.map(\.path))
        let unknownPath = paths?.contains { path in !rolloutPaths.contains { $0.path == path } } == true
        let needsCatalog = refreshCatalog || restarted
        if needsCatalog {
            let recoveringCatalog = !catalogAvailable
            let discovery = diagnostics.beginInterval(.databaseDiscovery)
            let dbURL = latestStateDatabase()
            diagnostics.endInterval(discovery, outcome: dbURL == nil ? .unavailable : .success)
            guard let dbURL, let catalog = queryRolloutPaths(from: dbURL) else {
                sourceAvailable = false
                catalogAvailable = false
                outcome = .unavailable
                return ActivityRefresh(snapshot: unavailable(at: now), catalogUnavailable: true)
            }
            rolloutPaths = catalog
            catalogWatchPaths = [dbURL.path, dbURL.path + "-wal"]
            catalogAvailable = true
            let allowed = Set(catalog.map(\.path))
            filesByPath = filesByPath.filter { allowed.contains($0.key) }
            unreadablePaths.formIntersection(allowed)
            // A new catalog entry always needs its initial state, even if its file event
            // arrived before the transaction that registered it in SQLite.
            selected.formUnion(recoveringCatalog ? allowed : allowed.subtracting(filesByPath.keys))
        }
        if paths == nil || restarted { selected = Set(rolloutPaths.map(\.path)) }
        let allowed = Set(rolloutPaths.map(\.path))
        for path in selected.intersection(allowed) {
            unreadablePaths.remove(path)
            if Task.isCancelled { outcome = .cancelled; return ActivityRefresh(snapshot: unavailable(at: now)) }
            sampledMetadataChecks += 1
            var info = stat()
            let status = stat(path, &info)
            let missing = status != 0 && errno == ENOENT
            guard status == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                filesByPath.removeValue(forKey: path)
                // Disappearing files are ordinary during archive/deletion. Other read
                // failures must not leave a cached active task behind.
                if !missing { sampledUnreadableFiles += 1; unreadablePaths.insert(path) }
                continue
            }
            let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)
                + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
            let metadata = ActivityFileMetadata(path: path, size: Int64(info.st_size), modifiedAt: modified,
                identity: ActivityFileIdentity(device: Int64(info.st_dev), inode: UInt64(info.st_ino)))
            let previous = filesByPath[path]
            if previous?.metadata != metadata { sampledChangedFiles += 1 }
            do {
                let updated = try update(metadata: metadata, previous: previous, sampledAt: now, launchDate: launchDate)
                guard !Task.isCancelled else { outcome = .cancelled; return ActivityRefresh(snapshot: unavailable(at: now)) }
                filesByPath[path] = updated
            } catch {
                filesByPath.removeValue(forKey: path)
                sampledUnreadableFiles += 1
                unreadablePaths.insert(path)
            }
        }
        sourceAvailable = catalogAvailable
        if !sourceAvailable { outcome = .unavailable }
        let result = reclassify(now: now)
        return ActivityRefresh(snapshot: result.snapshot, nextExpiry: result.nextExpiry,
            catalogNeeded: unknownPath && !needsCatalog,
            catalogUnavailable: !catalogAvailable,
            watchTargets: ActivityWatchTargets(sessions: allowed, catalogs: catalogWatchPaths))
    }

    func reclassify(now: Date = Date()) -> ActivityRefresh {
        guard desktopLaunchDate != nil else { return ActivityRefresh(snapshot: idle(at: now)) }
        let states = Array(filesByPath.values)
        var snapshot = CodexActivityClassifier.snapshot(states: states, sampledAt: now, sourceAvailable: sourceAvailable)
        if !unreadablePaths.isEmpty && !snapshot.isWorking { snapshot = unavailable(at: now) }
        let deadlines = states.compactMap { state -> Date? in
            if state.modifiedAt > now { return state.modifiedAt }
            switch state.lifecycle {
            case .active:
                guard let latest = [state.lastLifecycleAt, state.lastHeartbeatAt].compactMap({ $0 }).max() else { return nil }
                // Log timestamps can round a fraction of a millisecond ahead of
                // the sample. Revisit that boundary as well as freshness expiry.
                return latest.addingTimeInterval(latest > now ? 0.001 : CodexActivityClassifier.freshness + 0.001)
            case .unknown: return state.modifiedAt.addingTimeInterval(CodexActivityClassifier.freshness + 0.001)
            case .idle: return nil
            }
        }.filter { $0 > now }
        return ActivityRefresh(snapshot: snapshot, nextExpiry: sourceAvailable ? deadlines.min() : nil)
    }

    private func latestStateDatabase() -> URL? {
        let directories = [codexHome, codexHome.appendingPathComponent("sqlite", isDirectory: true)]
        let entries = directories.flatMap { directory in
            (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        }
        let unique = entries
            .filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
            .reduce(into: [String: URL]()) { $0[$1.standardizedFileURL.path] = $1 }
            .values
        return unique.sorted { lhs, rhs in
            let leftVersion = numericStateVersion(lhs)
            let rightVersion = numericStateVersion(rhs)
            if leftVersion != rightVersion { return leftVersion > rightVersion }
            // Newer installations keep the live catalog directly under CODEX_HOME;
            // prefer it over the legacy sqlite/ copy when versions tie.
            let rootPath = codexHome.appendingPathComponent(lhs.lastPathComponent).standardizedFileURL.path
            return lhs.standardizedFileURL.path == rootPath && rhs.standardizedFileURL.path != rootPath
        }.first
    }

    private func numericStateVersion(_ url: URL) -> Int {
        let stem = url.deletingPathExtension().lastPathComponent
        return Int(stem.dropFirst("state_".count)) ?? -1
    }

    private func queryRolloutPaths(from url: URL) -> [URL]? {
        let interval = diagnostics.beginInterval(.databaseQuery)
        var succeeded = false
        var fields: [String: DiagnosticValue] = [:]
        defer { diagnostics.endInterval(interval, outcome: succeeded ? .success : .unavailable, fields: fields) }
        // A read-only WAL connection needs its sidecar. Between writer shutdown
        // and recreation it may be absent; avoid repeatedly asking SQLite to
        // open it (and flooding the system log). Never ignore a live WAL using
        // immutable=1, or create/checkpoint Codex's database ourselves.
        if isWaitingForWAL(at: url) {
            fields["errorCategory"] = .string("walUnavailable")
            return nil
        }
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard openResult == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }

        var columns: Set<String> = []
        var info: OpaquePointer?
        if sqlite3_prepare_v2(database, "PRAGMA table_info(threads)", -1, &info, nil) == SQLITE_OK {
            defer { sqlite3_finalize(info) }
            while true {
                let result = sqlite3_step(info)
                if result == SQLITE_ROW, let name = sqlite3_column_text(info, 1) {
                    columns.insert(String(cString: name))
                } else if result == SQLITE_DONE {
                    break
                } else {
                    return nil
                }
            }
        }
        guard columns.contains("rollout_path"), columns.contains("archived") else { return nil }
        let order = columns.contains("updated_at_ms") ? "updated_at_ms" : (columns.contains("updated_at") ? "updated_at" : "rowid")
        let sql = "SELECT rollout_path FROM threads WHERE archived = 0 AND rollout_path IS NOT NULL ORDER BY \(order) DESC LIMIT \(maxCachedFiles)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var result: [URL] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW, let path = sqlite3_column_text(statement, 0) {
                let value = String(cString: path)
                let resolved: URL
                if value.hasPrefix("/") {
                    resolved = URL(fileURLWithPath: value, isDirectory: false)
                } else if value == "sessions" || value.hasPrefix("sessions/") {
                    resolved = codexHome.appendingPathComponent(value)
                } else {
                    resolved = sessionRoot.appendingPathComponent(value)
                }
                if isSessionPath(resolved) { result.append(resolved) }
            } else if step == SQLITE_DONE {
                break
            } else {
                return nil
            }
        }
        succeeded = true
        return result
    }

    private func isWaitingForWAL(at url: URL) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        guard let header = try? file.read(upToCount: 20), header.count == 20,
              header.prefix(16) == Data("SQLite format 3\0".utf8),
              header[18] == 2 || header[19] == 2 else { return false }
        var info = stat()
        return stat(url.path + "-wal", &info) != 0 && errno == ENOENT
    }

    private func isSessionPath(_ url: URL) -> Bool {
        let root = sessionRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
    }

    private func update(metadata: ActivityFileMetadata, previous: ActivityFileState?, sampledAt: Date, launchDate: Date?) throws -> ActivityFileState {
        var state = previous ?? ActivityFileState(metadata: metadata)
        let reset = previous == nil || metadata.identity != previous?.metadata.identity
            || metadata.size < state.offset || metadata.modifiedAt < state.modifiedAt
            || (metadata.size == state.offset && metadata.modifiedAt != state.modifiedAt)
        if reset {
            state = ActivityFileState(metadata: metadata)
            // Skipping an old file also consumes its existing extent. Leaving
            // offset at zero would read that history as growth on the next poll.
            state.offset = metadata.size
            guard metadata.modifiedAt >= sampledAt.addingTimeInterval(-activeWindow) else { return state }
            let data = try readTail(url: URL(fileURLWithPath: metadata.path, isDirectory: false), size: metadata.size)
            let result = CodexActivityParser.consume(data: data, state: &state, launchDate: launchDate)
            sampledParsedRecords += result.parsedRecords
            sampledParseFailures += result.parseFailures
        } else if metadata.size > state.offset {
            let growth = metadata.size - state.offset
            if growth > Int64(maxTailBytes) {
                state = ActivityFileState(metadata: metadata)
                let result = CodexActivityParser.consume(data: try readTail(url: URL(fileURLWithPath: metadata.path, isDirectory: false), size: metadata.size), state: &state, launchDate: launchDate)
                sampledParsedRecords += result.parsedRecords
                sampledParseFailures += result.parseFailures
            } else {
                let data = try readRange(url: URL(fileURLWithPath: metadata.path, isDirectory: false), offset: state.offset, length: growth)
                let result = CodexActivityParser.consume(data: data, state: &state, launchDate: launchDate)
                sampledParsedRecords += result.parsedRecords
                sampledParseFailures += result.parseFailures
            }
            state.offset = metadata.size
        }
        state.metadata = metadata
        state.modifiedAt = metadata.modifiedAt
        return state
    }

    private func readTail(url: URL, size: Int64) throws -> Data {
        let start = max(Int64(0), size - Int64(maxTailBytes))
        return try readRange(url: url, offset: start, length: size - start)
    }

    private func readRange(url: URL, offset: Int64, length: Int64) throws -> Data {
        guard length > 0 else { return Data() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(0, offset)))
        let data = try handle.read(upToCount: Int(min(length, Int64(maxTailBytes)))) ?? Data()
        // Do not commit an offset past bytes actually read if a writer truncated
        // or replaced the file between metadata acquisition and the read.
        guard data.count == Int(min(length, Int64(maxTailBytes))) else { throw CocoaError(.fileReadUnknown) }
        sampledBytesRead += data.count
        return data
    }

    private func unavailable(at date: Date) -> CodexActivitySnapshot {
        CodexActivitySnapshot(isWorking: false, activeTaskCount: 0, isAvailable: false, detail: "Codex activity unavailable", sampledAt: date)
    }

    private func idle(at date: Date) -> CodexActivitySnapshot {
        CodexActivitySnapshot(isWorking: false, activeTaskCount: 0, isAvailable: true, detail: "Codex idle", sampledAt: date)
    }
}

struct ActivityRefresh: Sendable {
    let snapshot: CodexActivitySnapshot
    var nextExpiry: Date? = nil
    var catalogNeeded = false
    var catalogUnavailable = false
    var watchTargets: ActivityWatchTargets? = nil
}

struct ActivityFileIdentity: Sendable, Equatable {
    let device: Int64
    let inode: UInt64
}

struct ActivityFileMetadata: Sendable, Equatable {
    let path: String
    let size: Int64
    let modifiedAt: Date
    var identity: ActivityFileIdentity? = nil
}

enum ActivityLifecycle: Sendable, Equatable { case unknown, active, idle }

struct ActivityFileState: Sendable, Equatable {
    var metadata: ActivityFileMetadata
    var offset: Int64 = 0
    var pending = Data()
    var lifecycle: ActivityLifecycle = .unknown
    var modifiedAt: Date
    var lastLifecycleAt: Date?
    var lastHeartbeatAt: Date?

    init(metadata: ActivityFileMetadata) {
        self.metadata = metadata
        self.modifiedAt = metadata.modifiedAt
    }
}

enum CodexActivityParser {
    struct ParseResult { let parsedRecords: Int; let parseFailures: Int }

    static func consume(data: Data, state: inout ActivityFileState, launchDate: Date?) -> ParseResult {
        var parsedRecords = 0
        var parseFailures = 0
        state.pending.append(data)
        while let newline = state.pending.firstIndex(of: 10) {
            if Task.isCancelled { break }
            let line = state.pending.prefix(upTo: newline)
            state.pending.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                parseFailures += 1
                continue
            }
            parsedRecords += 1
            guard object["type"] as? String == "event_msg" else { continue }
            guard let eventDate = eventDate(from: object) else {
                parseFailures += 1
                continue
            }
            if let launchDate, eventDate < launchDate { continue }
            guard let payload = object["payload"] as? [String: Any], let type = payload["type"] as? String else {
                parseFailures += 1
                continue
            }
            switch type {
            case "task_started":
                state.lifecycle = .active
                state.lastLifecycleAt = eventDate
                state.lastHeartbeatAt = nil
            case "task_complete", "turn_aborted":
                state.lifecycle = .idle
                state.lastLifecycleAt = eventDate
                state.lastHeartbeatAt = nil
            case "token_count", "item_completed":
                if state.lifecycle == .active { state.lastHeartbeatAt = eventDate }
            default:
                break
            }
        }
        if state.pending.count > 64 * 1024 { state.pending.removeAll(keepingCapacity: false) }
        return ParseResult(parsedRecords: parsedRecords, parseFailures: parseFailures)
    }

    private static func eventDate(from object: [String: Any]) -> Date? {
        guard let value = object["timestamp"] as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }()
    }
}

enum CodexActivityClassifier {
    static let freshness: TimeInterval = 15 * 60

    static func snapshot(states: [ActivityFileState], sampledAt: Date, sourceAvailable: Bool) -> CodexActivitySnapshot {
        guard sourceAvailable else {
            return CodexActivitySnapshot(isWorking: false, activeTaskCount: 0, isAvailable: false, detail: "Codex activity unavailable", sampledAt: sampledAt)
        }
        var active = 0
        var uncertain = false
        for state in states {
            let age = sampledAt.timeIntervalSince(state.modifiedAt)
            guard age >= 0 else { continue }
            switch state.lifecycle {
            case .active:
                guard let latestEvent = [state.lastLifecycleAt, state.lastHeartbeatAt].compactMap({ $0 }).max() else {
                    uncertain = true
                    continue
                }
                let eventAge = sampledAt.timeIntervalSince(latestEvent)
                if eventAge >= 0, eventAge <= freshness { active += 1 } else { uncertain = true }
            case .unknown:
                if age <= freshness { uncertain = true }
            case .idle:
                break
            }
        }
        if uncertain && active == 0 {
            return CodexActivitySnapshot(isWorking: false, activeTaskCount: 0, isAvailable: false, detail: "Codex activity unavailable", sampledAt: sampledAt)
        }
        if active > 0 {
            let noun = active == 1 ? "task" : "tasks"
            return CodexActivitySnapshot(isWorking: true, activeTaskCount: active, isAvailable: true, detail: "Codex active (\(active) \(noun))", sampledAt: sampledAt)
        }
        return CodexActivitySnapshot(isWorking: false, activeTaskCount: 0, isAvailable: true, detail: "Codex idle", sampledAt: sampledAt)
    }
}
