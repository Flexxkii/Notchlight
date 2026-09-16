import Foundation

/// Renders a human readable report from copied JSONL files. The report keeps
/// sessions separate because sequence numbers are only meaningful within one
/// recorder session.
internal enum DiagnosticReport {
    static func render(logURLs: [URL]) throws -> String {
        let input = try read(logURLs: logURLs)
        let sessions = Dictionary(grouping: input.events, by: { $0.session })
            .map { Session(id: $0.key, events: $0.value) }
            .sorted { $0.id < $1.id }

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
        var events: [Event] = []
        var corrupt = 0
        var corruptLast = 0
        for url in logURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let data = try Data(contentsOf: url)
            let lines = data.split(separator: 10, omittingEmptySubsequences: true)
            for (index, line) in lines.enumerated() {
                guard let lineText = String(data: Data(line), encoding: .utf8),
                      let lineData = lineText.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let session = object["sessionUUID"] as? String,
                      let event = object["event"] as? String else {
                    corrupt += 1
                    if index == lines.index(before: lines.endIndex) { corruptLast += 1 }
                    continue
                }
                let sequence = number(object["sequence"]).map { UInt64(max(0, $0)) } ?? 0
                let mono = number(object["monotonicNanoseconds"]).map { UInt64(max(0, $0)) } ?? 0
                let fields = object["fields"] as? [String: Any] ?? [:]
                events.append(Event(session: session, sequence: sequence, monotonic: mono, event: event, fields: fields))
            }
        }
        return Input(events: events, corruptLines: corrupt, corruptLastLines: corruptLast)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber else { return nil }
        return value.doubleValue.isFinite ? value.doubleValue : nil
    }

    private static func safe(_ value: String) -> String {
        value.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }.prefix(120).description
    }

    private struct Input {
        let events: [Event]
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

    private struct StateSample {
        let at: UInt64
        let fields: [String: Any]
        let context: [String: String]
        let valid: Bool
    }

    private struct Session {
        let id: String
        let events: [Event]
        let sorted: [Event]
        let sequenceGaps: Int
        let droppedEvents: Int
        let incompleteIntervals: Int
        let danglingBegins: Int
        let orphanEnds: Int
        let sampleGaps: Int
        let sampleUnavailable: Int
        let baselineResets: Int
        let samples: [Event]
        let stateSamples: [StateSample]
        let contexts: [(at: UInt64, values: [String: String])]
        let operations: [Operation]
        let helpers: [String: Helper]
        let counters: [String: (duration: UInt64, count: Int64)]

        init(id: String, events: [Event]) {
            self.id = id
            self.events = events
            sorted = events.sorted { lhs, rhs in
                if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
                return lhs.monotonic < rhs.monotonic
            }
            var gaps = 0
            var prior: UInt64?
            var context: [String: String] = [:]
            var contexts: [(UInt64, [String: String])] = []
            var samples: [Event] = []
            var stateSamples: [StateSample] = []
            var begins: [String: (String, UInt64)] = [:]
            var operations: [Operation] = []
            var helpers: [String: Helper] = [:]
            var counters: [String: (UInt64, Int64)] = [:]
            var dropped = 0
            var orphanEnds = 0
            var sampleGaps = 0
            var sampleUnavailable = 0
            var baselineResets = 0
            for item in sorted {
                if let prior, item.sequence > prior + 1 { gaps += Int(min(UInt64(Int.max), item.sequence - prior - 1)) }
                prior = max(prior ?? 0, item.sequence)
                if item.event == DiagnosticEventName.context.rawValue {
                    for (key, value) in item.fields { context[key] = DiagnosticReport.valueString(value) }
                    contexts.append((item.monotonic, context))
                }
                if item.event == DiagnosticEventName.resourceSample.rawValue {
                    let stateKeys = ["codex_connected", "codex_working", "settings_visible", "preview_pulse_active", "usage_available", "usage_stale", "border_enabled", "border_effective_enabled", "pulse_requested", "reduceMotion", "swipe.phase", "swipe.status", "menu", "visible", "mixedState"]
                    for key in stateKeys where item.fields[key] != nil { context[key] = DiagnosticReport.valueString(item.fields[key]!) }
                    contexts.append((item.monotonic, context))
                    samples.append(item)
                    if item.fields["sampleGap"] as? Bool == true { sampleGaps += 1 }
                    if item.fields["sampleAvailable"] as? Bool == false || item.fields["errorCategory"] != nil { sampleUnavailable += 1 }
                    let valid = item.fields["mixedState"] as? Bool != true && item.fields["cpuDeltaNanoseconds"] != nil && item.fields["elapsedNanoseconds"] != nil && item.fields["baseline"] == nil
                    stateSamples.append(StateSample(at: item.monotonic, fields: item.fields, context: context, valid: valid))
                }
                if item.event == DiagnosticEventName.lifecycle.rawValue, item.fields["phase"] as? String == "baselineReset" { baselineResets += 1 }
                if item.event == DiagnosticEventName.failure.rawValue {
                    dropped += Int(max(0, DiagnosticReport.number(item.fields["droppedCount"]) ?? 0))
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
            self.sequenceGaps = gaps
            self.droppedEvents = dropped
            self.samples = samples
            self.stateSamples = stateSamples
            self.contexts = contexts
            self.operations = operations
            self.helpers = helpers
            self.counters = counters
            incompleteIntervals = begins.count + orphanEnds
            danglingBegins = begins.count
            self.orphanEnds = orphanEnds
            self.sampleGaps = sampleGaps
            self.sampleUnavailable = sampleUnavailable
            self.baselineResets = baselineResets
        }

        var resourceReport: String {
            guard !samples.isEmpty else { return "### Resources\n\nNo resource samples recorded.\n\n" }
            var cpuWeighted = 0.0, wall: UInt64 = 0
            var memory: [UInt64] = [], diskReadDelta: UInt64 = 0, diskWriteDelta: UInt64 = 0, wakeupDelta: UInt64 = 0
            var interruptDelta: UInt64 = 0, pageinDelta: UInt64 = 0
            var firstMemory: UInt64?, lastMemory: UInt64?
            for sample in samples {
                if let cpu = u64(sample.fields["cpuDeltaNanoseconds"]), let elapsed = u64(sample.fields["elapsedNanoseconds"]), elapsed > 0 {
                    cpuWeighted += Double(cpu) * 100; wall += elapsed
                } else if sample.fields["baseline"] == nil, let cpu = number(sample.fields["cpuPercent"]) {
                    let elapsed = u64(sample.fields["elapsedNanoseconds"]) ?? 0
                    cpuWeighted += cpu * Double(elapsed); wall += elapsed
                }
                if let value = u64(sample.fields["physicalFootprintBytes"]) { memory.append(value); firstMemory = firstMemory ?? value; lastMemory = value }
                diskReadDelta += u64(sample.fields["diskReadDeltaBytes"]) ?? 0
                diskWriteDelta += u64(sample.fields["diskWriteDeltaBytes"]) ?? 0
                wakeupDelta += u64(sample.fields["packageIdleWakeupDelta"]) ?? 0
                interruptDelta += u64(sample.fields["interruptWakeupDelta"]) ?? 0
                pageinDelta += u64(sample.fields["pageinDelta"]) ?? 0
            }
            let cpuText = wall > 0 ? String(format: "%.2f%%", cpuWeighted / Double(wall)) : "unavailable"
            let growth = firstMemory.flatMap { first in lastMemory.map { last in signedBytes(last, from: first) } } ?? "unavailable"
            let peakCPU = samples.compactMap { number($0.fields["cpuPercent"]) }.max().map { String(format: "%.2f%%", $0) } ?? "unavailable"
            let peakMemory = memory.max().map(formatBytes) ?? "unavailable"
            return "### Resources\n\n- Weighted average app CPU: \(cpuText)\n- Peak app CPU: \(peakCPU)\n- Physical footprint: \(peakMemory) peak; first-to-last growth \(growth)\n- Disk read delta: \(formatBytes(diskReadDelta))\n- Disk write delta: \(formatBytes(diskWriteDelta))\n- Package idle wakeup delta: \(wakeupDelta)\n- Interrupt wakeup delta: \(interruptDelta)\n- Page-in delta: \(pageinDelta)\n\n"
        }

        var stateReport: String {
            let keys = ["codex_connected", "codex_working", "settings_visible", "preview_pulse_active", "visible", "reduceMotion"]
            let valid = stateSamples.filter(\.valid)
            guard !valid.isEmpty else { return "### Observed states\n\nNo valid state samples recorded.\n\n" }
            var grouped: [String: (samples: Int, cpu: UInt64, elapsed: UInt64, peakMemory: UInt64)] = [:]
            for sample in valid {
                let combo = keys.map { "\($0)=\(sample.context[$0] ?? "unknown")" }.joined(separator: ",")
                let current = grouped[combo] ?? (0, 0, 0, 0)
                grouped[combo] = (current.samples + 1,
                                  current.cpu + (u64(sample.fields["cpuDeltaNanoseconds"]) ?? 0),
                                  current.elapsed + (u64(sample.fields["elapsedNanoseconds"]) ?? 0),
                                  max(current.peakMemory, u64(sample.fields["physicalFootprintBytes"]) ?? 0))
            }
            var text = "### Observed states\n\n| State combination | Samples | Observed interval (s) | Weighted CPU | Peak memory |\n|---|---:|---:|---:|---:|\n"
            for (combo, value) in grouped.sorted(by: { $0.key < $1.key }) {
                let cpu = value.elapsed > 0 ? String(format: "%.2f%%", 100 * Double(value.cpu) / Double(value.elapsed)) : "unavailable"
                text += "| \(combo) | \(value.samples) | \(String(format: "%.3f", Double(value.elapsed) / 1_000_000_000)) | \(cpu) | \(formatBytes(value.peakMemory)) |\n"
            }
            let mixed = stateSamples.filter { $0.fields["mixedState"] as? Bool == true }.count
            return text + "\nMixed samples excluded from state rows: \(mixed). CPU and resource metrics are not attributed exclusively to any state.\n\n"
        }

        var operationReport: String {
            var text = "### Operations\n\n"
            if operations.isEmpty { return text + "No complete operation intervals recorded.\n\n" }
            var grouped: [String: Operation] = [:]
            for op in operations {
                let old = grouped[op.name]
                grouped[op.name] = Operation(name: op.name,
                                              durations: (old?.durations ?? []) + op.durations,
                                              count: (old?.count ?? 0) + op.count,
                                              failures: (old?.failures ?? 0) + op.failures)
            }
            for op in grouped.values.sorted(by: { $0.name < $1.name }) {
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

        private static func consumeOperation(_ item: Event, begins: inout [String: (String, UInt64)], output: inout [Operation], orphanEnds: inout Int) {
            let name = item.fields["operation"] as? String ?? "unknown"
            let key = item.fields["intervalID"].map { "\(name)#\(DiagnosticReport.valueString($0))" } ?? name
            if item.fields["phase"] as? String == "begin" { begins[key] = (name, item.monotonic); return }
            guard item.fields["phase"] as? String == "end" else { return }
            if !begins.keys.contains(key) { orphanEnds += 1 }
            let duration = DiagnosticReport.u64(item.fields["durationNanoseconds"]) ?? begins.removeValue(forKey: key).map { item.monotonic &- $0.1 } ?? 0
            let failed = (item.fields["outcome"] as? String).map { $0 != "success" } ?? false
            output.append(Operation(name: name, durations: [duration], count: 1, failures: failed ? 1 : 0))
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

    private struct Operation { let name: String; let durations: [UInt64]; let count: Int; let failures: Int }
    private struct Helper { let id: String; var samples = 0; var maxCPUTime: UInt64 = 0; var hasCPUTime = false; var maxMemory: UInt64?; var partial = false }
    private static func u64(_ value: Any?) -> UInt64? { number(value).flatMap { $0 >= 0 ? UInt64($0) : nil } }
    private static func valueString(_ value: Any) -> String { if let s = value as? String { return s }; if let b = value as? Bool { return b ? "true" : "false" }; return String(describing: value) }
    private static func delta(_ value: Any?, previous: Any?) -> UInt64 { guard let a = u64(value), let b = u64(previous), a >= b else { return 0 }; return a - b }
    private static func formatBytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .binary) }
    private static func signedBytes(_ last: UInt64, from first: UInt64) -> String { last >= first ? "+\(formatBytes(last - first))" : "-\(formatBytes(first - last))" }
    private static func formatDuration(_ value: UInt64) -> String { String(format: "%.3f ms", Double(value) / 1_000_000) }
    private static func percentile(_ values: [UInt64], _ p: Double) -> UInt64 { guard !values.isEmpty else { return 0 }; let sorted = values.sorted(); return sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * p)) - 1)] }
}
