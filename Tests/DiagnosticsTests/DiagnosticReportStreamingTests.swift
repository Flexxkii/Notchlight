import Foundation
import Testing
@testable import Diagnostics

@Suite("Streaming diagnostic report")
struct DiagnosticReportStreamingTests {
    @Test("preserves the complete report across chunks, rotated files, and equal sort keys")
    func completeReport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("session-a.jsonl")
        let b = root.appendingPathComponent("session-b.jsonl")
        let c = root.appendingPathComponent("session-c.jsonl")
        let aData = Data("\n".utf8) + Data([0xff]) + Data(("\n"
            + line(1, "lifecycle", ["phase": "sessionStart"], session: "A")
            + line(3, "futureEvent", [:], session: "A")).utf8)
        try aData.write(to: a)
        // A multibyte field crosses the reader's 64 KiB window. The input is
        // intentionally unsorted and includes fields that never enter the report.
        let bLines = [
            line(19, "helperSample", ["helperLaunchUUID": "helper-1", "userTimeNanoseconds": 100_000_000, "systemTimeNanoseconds": 10_000_000, "physicalFootprintBytes": 4096, "partial": true]),
            line(2, "resourceSample", ["physicalFootprintBytes": 1024, "unused": String(repeating: "✨", count: 24_000)]),
            line(4, "operation", ["operation": "rpcLimits", "phase": "begin", "intervalID": 7]),
            line(6, "operation", ["operation": "rpcLimits", "phase": "end", "intervalID": 7, "durationNanoseconds": 1_500_000, "outcome": "failed"]),
            line(8, "resourceSample", ["cpuPercent": 12.5, "elapsedNanoseconds": 2_000_000_000, "physicalFootprintBytes": 2048]),
            line(9, "helperLifecycle", ["launchID": "helper-1", "phase": "launched"]),
            line(10, "failure", ["droppedCount": 3]),
            line(12, "counters", ["mouse.count": 3, "mouse.durationNanoseconds": 2_000_000]),
            line(13, "context", ["codex_connected": true, "codex_working": true, "settings_visible": false, "preview_pulse_active": false, "visible": true, "reduceMotion": false]),
            line(14, "context", ["codex_working": false]),
            line(15, "resourceSample", ["cpuDeltaNanoseconds": 500_000_000, "elapsedNanoseconds": 1_000_000_000, "cpuPercent": 50, "physicalFootprintBytes": 4096, "diskReadDeltaBytes": 2048, "diskWriteDeltaBytes": 512, "packageIdleWakeupDelta": 3, "interruptWakeupDelta": 2, "pageinDelta": 1]),
            line(16, "resourceSample", ["cpuDeltaNanoseconds": 100_000_000, "elapsedNanoseconds": 1_000_000_000, "physicalFootprintBytes": 2048, "mixedState": true, "sampleGap": true, "sampleAvailable": false, "errorCategory": "samplingFailed", "codex_working": false]),
            line(17, "lifecycle", ["phase": "baselineReset"]),
            line(18, "operation", ["operation": "rpcLimits", "phase": "end", "durationNanoseconds": 500_000, "outcome": "unavailable"]),
            line(20, "operation", ["operation": "activityRead", "phase": "begin"]),
            line(21, "helperSample", ["launchID": "helper-1", "userTimeNanoseconds": 200_000_000, "systemTimeNanoseconds": 20_000_000, "physicalFootprintBytes": 8192])
        ]
        try ("not json\n" + bLines.joined() + "{\"broken\"\n\n").write(to: b, atomically: true, encoding: .utf8)
        // Equal sequence/monotonic keys keep their original file order. The last
        // valid record lacks a newline; trailing empty lines above are ignored.
        let cLines = line(14, "context", ["codex_working": true])
            + String(line(22, "counters", ["mouse.count": 2, "mouse.durationNanoseconds": 1_000_000]).dropLast())
        try cLines.write(to: c, atomically: true, encoding: .utf8)
        let report = try DiagnosticReport.render(logURLs: [c, b, a])
        #expect(report == Self.expectedReport)
    }

    @Test("empty files and blank lines preserve corruption accounting")
    func emptyAndBlankFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = ["", "\n\n", "\r\n\n"]
        let urls = try contents.enumerated().map { index, contents in
            let url = root.appendingPathComponent("session-\(index).jsonl")
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let report = try DiagnosticReport.render(logURLs: urls)
        #expect(report.contains("Sessions: 0"))
        #expect(report.contains("Files read: 3"))
        #expect(report.contains("Corrupt lines: 1\n"))
        #expect(report.contains("Corrupt last lines: 1\n"))
        #expect(report.hasSuffix("No valid diagnostic events were found.\n"))
    }

    private func line(_ sequence: Int, _ event: String, _ fields: [String: Any], session: String = "B") -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["sessionUUID": session, "sequence": sequence,
            "monotonicNanoseconds": sequence * 1_000_000, "event": event, "fields": fields], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    // Captured from the pre-optimization renderer. Only the system's localized
    // byte-unit strings are substituted so the fixture works across Mac locales.
    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .binary)
    }

    private static var expectedReport: String {
        """
        # Notchlight diagnostics

        Sessions: 2

        The report contains measured local diagnostics only. It does not contain prompts, responses, tokens, paths, or payloads.

        CPU is measured per core: 100% means one fully occupied core. Peaks are sampled observations; brief spikes may be higher. GPU utilization and watts are not measured. State associations and operation timings are evidence for investigation, not exclusive CPU attribution.

        ## Data quality

        - Files read: 3
        - Corrupt lines: 3
        - Corrupt last lines: 1
        - Sequence gaps: 5
        - Dropped events: 3
        - Incomplete intervals: 2
        - Sample gaps: 1
        - Multiple recorder sessions were observed and were kept separate.

        ## Session `A`

        Data quality: unavailable samples 0, sample gaps 0, baseline resets 0, dangling begins 0, orphan ends 0.

        ### Resources

        No resource samples recorded.

        ### Observed states

        No valid state samples recorded.

        ### Operations

        No complete operation intervals recorded.

        ### Helpers

        No helper lifecycle or sample events recorded.

        ### Aggregated counters

        No aggregated counters recorded.


        ## Session `B`

        Data quality: unavailable samples 1, sample gaps 1, baseline resets 1, dangling begins 1, orphan ends 1.

        ### Resources

        - Weighted average app CPU: 21.25%
        - Peak app CPU: 50.00%
        - Physical footprint: \(bytes(4096)) peak; first-to-last growth +\(bytes(1024))
        - Disk read delta: \(bytes(2048))
        - Disk write delta: \(bytes(512))
        - Package idle wakeup delta: 3
        - Interrupt wakeup delta: 2
        - Page-in delta: 1

        ### Observed states

        | State combination | Samples | Observed interval (s) | Weighted CPU | Peak memory |
        |---|---:|---:|---:|---:|
        | codex_connected=true,codex_working=true,settings_visible=false,preview_pulse_active=false,visible=true,reduceMotion=false | 1 | 1.000 | 50.00% | \(bytes(4096)) |

        Mixed samples excluded from state rows: 1. CPU and resource metrics are not attributed exclusively to any state.

        ### Operations

        - `rpcLimits`: 2 calls, 2 failed, average 1.000 ms, p95 1.500 ms, max 1.500 ms

        ### Helpers

        - `helper-1`: 2 samples, observed CPU time 220 ms, peak memory \(bytes(8192)), partial yes

        ### Aggregated counters

        - `mouse`: count 5, duration 3.00 ms

        """ + "\n"
    }
}
