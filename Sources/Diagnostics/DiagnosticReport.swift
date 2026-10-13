import Foundation

/// Renders a human readable report from copied JSONL files. The report keeps
/// sessions separate because sequence numbers are only meaningful within one
/// recorder session.
internal enum DiagnosticReport {
    static func render(logURLs: [URL]) throws -> String {
        let input = try read(logURLs: logURLs)
        let reader = RecordReader(urls: input.urls)
        defer { reader.close() }
        let sessions = try input.records.keys.sorted().map { id in
            try Session(id: id, records: input.records[id] ?? [], reader: reader)
        }

        var report = "# Notchlight diagnostics\n\n"
        report += "Sessions: \(sessions.count)\n\n"
        report += "The report contains measured local diagnostics only. It does not contain prompts, responses, tokens, paths, or payloads.\n\n"
        report += "CPU is measured per core: 100% means one fully occupied core. Peaks are sampled observations; brief spikes may be higher. GPU utilization and watts are not measured. State associations and operation timings are evidence for investigation, not exclusive CPU attribution.\n\n"
        report += "## Data quality\n\n"
        report += "- Files read: \(logURLs.count)\n"
        report += "- Corrupt lines: \(input.corruptLines)\n"
        report += "- Corrupt last lines: \(input.corruptLastLines)\n"
        report += "- Sequence gaps: \(sessions.reduce(0) { $0 + $1.sequenceGaps })\n"
        report += "- Dropped events: \(sessions.reduce(0) { $0 + $1.droppedEvents })\n"
        report += "- Incomplete intervals: \(sessions.reduce(0) { $0 + $1.incompleteIntervals })\n"
        report += "- Sample gaps: \(sessions.reduce(0) { $0 + $1.sampleGaps })\n"
        if sessions.count > 1 { report += "- Multiple recorder sessions were observed and were kept separate.\n" }

        for session in sessions {
            report += "\n## Session `\(safe(session.id))`\n\n"
            report += "Data quality: unavailable samples \(session.sampleUnavailable), sample gaps \(session.sampleGaps), baseline resets \(session.baselineResets), dangling begins \(session.danglingBegins), orphan ends \(session.orphanEnds).\n\n"
            report += session.resourceReport
            report += session.stateReport
            report += session.operationReport
            report += session.helperReport
            report += session.counterReport
        }
        if sessions.isEmpty { report += "No valid diagnostic events were found.\n" }
        return report
    }

    private static func read(logURLs: [URL]) throws -> Input {
        let urls = logURLs.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var records: [String: [RecordLocation]] = [:]
        var corrupt = 0
        var corruptLast = 0
        var order = 0
        for (fileIndex, url) in urls.enumerated() {
            var lastWasCorrupt = false
            try scanLines(in: url) { data, offset in
                autoreleasepool {
                    guard let event = decode(data) else {
                        corrupt += 1
                        lastWasCorrupt = true
                        return
                    }
                    lastWasCorrupt = false
                    records[event.session, default: []].append(RecordLocation(
                        fileIndex: fileIndex, offset: offset, length: data.count,
                        sequence: event.sequence, monotonic: event.monotonic, order: order))
                    order += 1
                }
            }
            if lastWasCorrupt { corruptLast += 1 }
        }
        return Input(urls: urls, records: records, corruptLines: corrupt, corruptLastLines: corruptLast)
    }

    /// Keep only byte locations while sorting. Copied export logs remain immutable
    /// across both passes; decoded Foundation objects are released after each line.
    private static func scanLines(in url: URL, consume: (Data, UInt64) -> Void) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var buffer = Data()
        var offset: UInt64 = 0
        while let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let length = buffer.distance(from: buffer.startIndex, to: newline)
                if length > 0 { consume(Data(buffer.prefix(length)), offset) }
                buffer.removeSubrange(...newline)
                offset += UInt64(length + 1)
            }
        }
        if !buffer.isEmpty { consume(buffer, offset) }
    }

    private static func decode(_ data: Data) -> Event? {
        guard let text = String(data: data, encoding: .utf8),
              let utf8 = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: utf8) as? [String: Any],
              let session = object["sessionUUID"] as? String,
              let event = object["event"] as? String else { return nil }
        return Event(session: session,
            sequence: number(object["sequence"]).map { UInt64(max(0, $0)) } ?? 0,
            monotonic: number(object["monotonicNanoseconds"]).map { UInt64(max(0, $0)) } ?? 0,
            event: event, fields: object["fields"] as? [String: Any] ?? [:])
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber else { return nil }
        return value.doubleValue.isFinite ? value.doubleValue : nil
    }

    private static func safe(_ value: String) -> String {
        value.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }.prefix(120).description
    }

    private struct Input {
        let urls: [URL]
        let records: [String: [RecordLocation]]
        let corruptLines: Int
        let corruptLastLines: Int
    }

    private struct Event {
        let session: String
        let sequence: UInt64
        let monotonic: UInt64
        let event: String
        let fields: [String: Any]
    }

    private struct RecordLocation {
        let fileIndex: Int
        let offset: UInt64
        let length: Int
        let sequence: UInt64
        let monotonic: UInt64
        let order: Int
    }

    /// One open file and one read window bound I/O buffers even for many sessions.
    private final class RecordReader {
        let urls: [URL]
        var file: FileHandle?
        var fileIndex: Int?
        var buffer = Data()
        var offset: UInt64 = 0

        init(urls: [URL]) { self.urls = urls }

        func close() { try? file?.close(); file = nil }

        func event(at record: RecordLocation) throws -> Event {
            if fileIndex != record.fileIndex {
                close()
                file = try FileHandle(forReadingFrom: urls[record.fileIndex])
                fileIndex = record.fileIndex
                buffer = Data()
            }
            guard let file else { throw CocoaError(.fileReadUnknown) }
            if record.offset < offset || record.offset + UInt64(record.length) > offset + UInt64(buffer.count) {
                try file.seek(toOffset: record.offset)
                buffer = try file.read(upToCount: max(64 * 1024, record.length)) ?? Data()
                offset = record.offset
            }
            let start = Int(record.offset - offset)
            guard start + record.length <= buffer.count,
                  let event = decode(buffer.subdata(in: start..<(start + record.length))) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return event
        }
    }

    private struct StateTotals {
        var samples = 0
        var cpu: UInt64 = 0
        var elapsed: UInt64 = 0
        var peakMemory: UInt64 = 0
    }

    private struct ResourceTotals {
        var samples = 0
        var cpuWeighted = 0.0
        var wall: UInt64 = 0
        var firstMemory: UInt64?
        var lastMemory: UInt64?
        var peakMemory: UInt64?
        var peakCPU: Double?
        var diskReadDelta: UInt64 = 0
        var diskWriteDelta: UInt64 = 0
        var wakeupDelta: UInt64 = 0
        var interruptDelta: UInt64 = 0
        var pageinDelta: UInt64 = 0

        mutating func consume(_ fields: [String: Any]) {
            samples += 1
            if let cpu = u64(fields["cpuDeltaNanoseconds"]), let elapsed = u64(fields["elapsedNanoseconds"]), elapsed > 0 {
                cpuWeighted += Double(cpu) * 100; wall += elapsed
            } else if fields["baseline"] == nil, let cpu = number(fields["cpuPercent"]) {
                let elapsed = u64(fields["elapsedNanoseconds"]) ?? 0
                cpuWeighted += cpu * Double(elapsed); wall += elapsed
            }
            if let value = u64(fields["physicalFootprintBytes"]) {
                firstMemory = firstMemory ?? value; lastMemory = value
                peakMemory = max(peakMemory ?? value, value)
            }
            if let value = number(fields["cpuPercent"]) { peakCPU = max(peakCPU ?? value, value) }
            diskReadDelta += u64(fields["diskReadDeltaBytes"]) ?? 0
            diskWriteDelta += u64(fields["diskWriteDeltaBytes"]) ?? 0
            wakeupDelta += u64(fields["packageIdleWakeupDelta"]) ?? 0
            interruptDelta += u64(fields["interruptWakeupDelta"]) ?? 0
            pageinDelta += u64(fields["pageinDelta"]) ?? 0
        }
    }

    private struct Session {
        let id: String
        var sequenceGaps = 0
        var droppedEvents = 0
        var incompleteIntervals = 0
        var danglingBegins = 0
        var orphanEnds = 0
        var sampleGaps = 0
        var sampleUnavailable = 0
        var baselineResets = 0
        var resources = ResourceTotals()
        var stateGroups: [String: StateTotals] = [:]
        var mixedSamples = 0
        var operations: [String: Operation] = [:]
        var helpers: [String: Helper] = [:]
        var counters: [String: (duration: UInt64, count: Int64)] = [:]
        private static let stateKeys = ["codex_connected", "codex_working", "settings_visible", "preview_pulse_active", "visible", "reduceMotion"]

        init(id: String, records: [RecordLocation], reader: RecordReader) throws {
            self.id = id
            let sorted = records.sorted { lhs, rhs in
                if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
                if lhs.monotonic != rhs.monotonic { return lhs.monotonic < rhs.monotonic }
                return lhs.order < rhs.order
            }
            var prior: UInt64?
            var context: [String: String] = [:]
            var begins: [String: (String, UInt64)] = [:]
            for record in sorted {
                try autoreleasepool {
                    let item = try reader.event(at: record)
                    if let prior, item.sequence > prior + 1 { sequenceGaps += Int(min(UInt64(Int.max), item.sequence - prior - 1)) }
                    prior = max(prior ?? 0, item.sequence)
                    if item.event == DiagnosticEventName.context.rawValue {
                        for key in Self.stateKeys where item.fields[key] != nil { context[key] = DiagnosticReport.valueString(item.fields[key]!) }
                    }
                    if item.event == DiagnosticEventName.resourceSample.rawValue {
                        for key in Self.stateKeys where item.fields[key] != nil { context[key] = DiagnosticReport.valueString(item.fields[key]!) }
                        resources.consume(item.fields)
                        if item.fields["sampleGap"] as? Bool == true { sampleGaps += 1 }
                        if item.fields["sampleAvailable"] as? Bool == false || item.fields["errorCategory"] != nil { sampleUnavailable += 1 }
                        let valid = item.fields["mixedState"] as? Bool != true && item.fields["cpuDeltaNanoseconds"] != nil && item.fields["elapsedNanoseconds"] != nil && item.fields["baseline"] == nil
                        if item.fields["mixedState"] as? Bool == true { mixedSamples += 1 }
                        if valid {
                            let combo = Self.stateKeys.map { "\($0)=\(context[$0] ?? "unknown")" }.joined(separator: ",")
                            stateGroups[combo, default: StateTotals()].samples += 1
                            stateGroups[combo, default: StateTotals()].cpu += u64(item.fields["cpuDeltaNanoseconds"]) ?? 0
                            stateGroups[combo, default: StateTotals()].elapsed += u64(item.fields["elapsedNanoseconds"]) ?? 0
                            stateGroups[combo, default: StateTotals()].peakMemory = max(stateGroups[combo]?.peakMemory ?? 0, u64(item.fields["physicalFootprintBytes"]) ?? 0)
                        }
                    }
                    if item.event == DiagnosticEventName.lifecycle.rawValue, item.fields["phase"] as? String == "baselineReset" { baselineResets += 1 }
                    if item.event == DiagnosticEventName.failure.rawValue {
                        droppedEvents += Int(max(0, DiagnosticReport.number(item.fields["droppedCount"]) ?? 0))
                    }
                    if item.event == DiagnosticEventName.operation.rawValue { Self.consumeOperation(item, begins: &begins, output: &operations, orphanEnds: &orphanEnds) }
                    if item.event == DiagnosticEventName.helperLifecycle.rawValue || item.event == DiagnosticEventName.helperSample.rawValue {
                        Self.consumeHelper(item, into: &helpers)
                    }
                    if item.event == DiagnosticEventName.counters.rawValue {
                        for (key, value) in item.fields where key.hasSuffix(".count") || key.hasSuffix(".durationNanoseconds") {
                            let current = counters[key] ?? (0, 0)
                            if key.hasSuffix(".count") { counters[key] = (current.0, current.1 + Int64(DiagnosticReport.number(value) ?? 0)) }
                            else { counters[key] = (current.0 + UInt64(max(0, DiagnosticReport.number(value) ?? 0)), current.1) }
                        }
                    }
                }
            }
            incompleteIntervals = begins.count + orphanEnds
            danglingBegins = begins.count
        }

        var resourceReport: String {
            guard resources.samples > 0 else { return "### Resources\n\nNo resource samples recorded.\n\n" }
            let cpuText = resources.wall > 0 ? String(format: "%.2f%%", resources.cpuWeighted / Double(resources.wall)) : "unavailable"
            let growth = resources.firstMemory.flatMap { first in resources.lastMemory.map { last in signedBytes(last, from: first) } } ?? "unavailable"
            let peakCPU = resources.peakCPU.map { String(format: "%.2f%%", $0) } ?? "unavailable"
            let peakMemory = resources.peakMemory.map(formatBytes) ?? "unavailable"
            return "### Resources\n\n- Weighted average app CPU: \(cpuText)\n- Peak app CPU: \(peakCPU)\n- Physical footprint: \(peakMemory) peak; first-to-last growth \(growth)\n- Disk read delta: \(formatBytes(resources.diskReadDelta))\n- Disk write delta: \(formatBytes(resources.diskWriteDelta))\n- Package idle wakeup delta: \(resources.wakeupDelta)\n- Interrupt wakeup delta: \(resources.interruptDelta)\n- Page-in delta: \(resources.pageinDelta)\n\n"
        }

        var stateReport: String {
            guard !stateGroups.isEmpty else { return "### Observed states\n\nNo valid state samples recorded.\n\n" }
            var text = "### Observed states\n\n| State combination | Samples | Observed interval (s) | Weighted CPU | Peak memory |\n|---|---:|---:|---:|---:|\n"
            for (combo, value) in stateGroups.sorted(by: { $0.key < $1.key }) {
                let cpu = value.elapsed > 0 ? String(format: "%.2f%%", 100 * Double(value.cpu) / Double(value.elapsed)) : "unavailable"
                text += "| \(combo) | \(value.samples) | \(String(format: "%.3f", Double(value.elapsed) / 1_000_000_000)) | \(cpu) | \(formatBytes(value.peakMemory)) |\n"
            }
            return text + "\nMixed samples excluded from state rows: \(mixedSamples). CPU and resource metrics are not attributed exclusively to any state.\n\n"
        }

        var operationReport: String {
            var text = "### Operations\n\n"
            if operations.isEmpty { return text + "No complete operation intervals recorded.\n\n" }
            for op in operations.values.sorted(by: { $0.name < $1.name }) {
                text += "- `\(safe(op.name))`: \(op.count) calls, \(op.failures) failed, average \(formatDuration(op.durations.reduce(0, +) / UInt64(max(1, op.count)))), p95 \(formatDuration(percentile(op.durations, 0.95))), max \(formatDuration(op.durations.max() ?? 0))\n"
            }
            return text + "\n"
        }

        var helperReport: String {
            var text = "### Helpers\n\n"
            if helpers.isEmpty { return text + "No helper lifecycle or sample events recorded.\n\n" }
            for helper in helpers.values.sorted(by: { $0.id < $1.id }) {
                let cpu = helper.hasCPUTime ? "\(String(format: "%.0f", Double(helper.maxCPUTime) / 1_000_000)) ms" : "unavailable"
                text += "- `\(safe(helper.id))`: \(helper.samples) samples, observed CPU time \(cpu), peak memory \(helper.maxMemory.map(formatBytes) ?? "unavailable"), partial \(helper.partial ? "yes" : "no")\n"
            }
            return text + "\n"
        }

        var counterReport: String {
            var text = "### Aggregated counters\n\n"
            if counters.isEmpty { return text + "No aggregated counters recorded.\n\n" }
            var grouped: [String: (count: Int64, duration: UInt64)] = [:]
            for (key, value) in counters {
                let base = key.hasSuffix(".count") ? String(key.dropLast(".count".count)) : String(key.dropLast(".durationNanoseconds".count))
                let old = grouped[base] ?? (0, 0)
                grouped[base] = (old.count + (key.hasSuffix(".count") ? value.count : 0), old.duration + (key.hasSuffix(".count") ? 0 : value.duration))
            }
            for key in grouped.keys.sorted() {
                let value = grouped[key]!
                text += "- `\(safe(key))`: count \(value.count), duration \(String(format: "%.2f", Double(value.duration) / 1_000_000)) ms\n"
            }
            return text + "\n"
        }

        private static func consumeOperation(_ item: Event, begins: inout [String: (String, UInt64)], output: inout [String: Operation], orphanEnds: inout Int) {
            let name = item.fields["operation"] as? String ?? "unknown"
            let key = item.fields["intervalID"].map { "\(name)#\(DiagnosticReport.valueString($0))" } ?? name
            if item.fields["phase"] as? String == "begin" { begins[key] = (name, item.monotonic); return }
            guard item.fields["phase"] as? String == "end" else { return }
            if !begins.keys.contains(key) { orphanEnds += 1 }
            let duration = DiagnosticReport.u64(item.fields["durationNanoseconds"]) ?? begins.removeValue(forKey: key).map { item.monotonic &- $0.1 } ?? 0
            let failed = (item.fields["outcome"] as? String).map { $0 != "success" } ?? false
            output[name, default: Operation(name: name)].durations.append(duration)
            output[name, default: Operation(name: name)].count += 1
            if failed { output[name, default: Operation(name: name)].failures += 1 }
            begins.removeValue(forKey: key)
        }
        private static func consumeHelper(_ item: Event, into helpers: inout [String: Helper]) {
            let id = (item.fields["launchID"] as? String) ?? (item.fields["helperLaunchUUID"] as? String) ?? "unknown"
            var helper = helpers[id] ?? Helper(id: id)
            helper.samples += item.event == DiagnosticEventName.helperSample.rawValue ? 1 : 0
            let cpuTime = (DiagnosticReport.u64(item.fields["userTimeNanoseconds"]) ?? 0) &+ (DiagnosticReport.u64(item.fields["systemTimeNanoseconds"]) ?? 0)
            helper.hasCPUTime = helper.hasCPUTime || (item.fields["userTimeNanoseconds"] != nil && item.fields["systemTimeNanoseconds"] != nil)
            helper.maxCPUTime = max(helper.maxCPUTime, cpuTime)
            if let memory = DiagnosticReport.u64(item.fields["physicalFootprintBytes"]) { helper.maxMemory = max(helper.maxMemory ?? 0, memory) }
            if item.fields["phase"] as? String == "partial" || item.fields["partial"] as? Bool == true { helper.partial = true }
            helpers[id] = helper
        }

        private func number(_ value: Any?) -> Double? { DiagnosticReport.number(value) }
        private func u64(_ value: Any?) -> UInt64? { DiagnosticReport.u64(value) }
        private func formatBytes(_ value: UInt64) -> String { DiagnosticReport.formatBytes(value) }
        private func signedBytes(_ last: UInt64, from first: UInt64) -> String { DiagnosticReport.signedBytes(last, from: first) }
        private func formatDuration(_ value: UInt64) -> String { DiagnosticReport.formatDuration(value) }
        private func percentile(_ values: [UInt64], _ p: Double) -> UInt64 { DiagnosticReport.percentile(values, p) }
        private func safe(_ value: String) -> String { DiagnosticReport.safe(value) }
    }

    private struct Operation { let name: String; var durations: [UInt64] = []; var count = 0; var failures = 0 }
    private struct Helper { let id: String; var samples = 0; var maxCPUTime: UInt64 = 0; var hasCPUTime = false; var maxMemory: UInt64?; var partial = false }
    private static func u64(_ value: Any?) -> UInt64? { number(value).flatMap { $0 >= 0 ? UInt64($0) : nil } }
    private static func valueString(_ value: Any) -> String { if let s = value as? String { return s }; if let b = value as? Bool { return b ? "true" : "false" }; return String(describing: value) }
    private static func delta(_ value: Any?, previous: Any?) -> UInt64 { guard let a = u64(value), let b = u64(previous), a >= b else { return 0 }; return a - b }
    private static func formatBytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .binary) }
    private static func signedBytes(_ last: UInt64, from first: UInt64) -> String { last >= first ? "+\(formatBytes(last - first))" : "-\(formatBytes(first - last))" }
    private static func formatDuration(_ value: UInt64) -> String { String(format: "%.3f ms", Double(value) / 1_000_000) }
    private static func percentile(_ values: [UInt64], _ p: Double) -> UInt64 { guard !values.isEmpty else { return 0 }; let sorted = values.sorted(); return sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * p)) - 1)] }
}
