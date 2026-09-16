import Foundation
import Testing
@testable import Diagnostics

@Suite("Diagnostic report")
struct DiagnosticReportTests {
    @Test("sorts sessions independently and reports weighted resources")
    func sessionsAndWeightedResources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostic-report-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("session-b.jsonl")
        let second = root.appendingPathComponent("session-a.jsonl")
        try write(lines: [
            line(session: "B", sequence: 2, mono: 2_000, event: "resourceSample", fields: ["cpuDeltaNanoseconds": 200, "elapsedNanoseconds": 1_000, "physicalFootprintBytes": 200, "diskReadDeltaBytes": 10, "packageIdleWakeupDelta": 5, "sampleGap": false]),
            line(session: "B", sequence: 1, mono: 1_000, event: "resourceSample", fields: ["physicalFootprintBytes": 100]),
            line(session: "B", sequence: 3, mono: 3_000, event: "context", fields: ["codex_connected": true, "codex_working": true, "settings_visible": false, "preview_pulse_active": false, "visible": true, "reduceMotion": false]),
            line(session: "B", sequence: 4, mono: 4_000, event: "resourceSample", fields: ["cpuDeltaNanoseconds": 100, "elapsedNanoseconds": 1_000, "mixedState": true, "codex_connected": false, "codex_working": false, "visible": false]),
            line(session: "B", sequence: 5, mono: 5_000, event: "helperSample", fields: ["launchID": "helper-1", "userTimeNanoseconds": 100_000_000, "systemTimeNanoseconds": 50_000_000]),
            line(session: "B", sequence: 6, mono: 6_000, event: "helperSample", fields: ["launchID": "helper-1", "userTimeNanoseconds": 200_000_000, "systemTimeNanoseconds": 100_000_000, "partial": true])
        ], to: first)
        try write(lines: [
            line(session: "A", sequence: 1, mono: 10, event: "lifecycle", fields: ["phase": "sessionStart"])
        ], to: second)

        let report = try DiagnosticReport.render(logURLs: [first, second])
        #expect(report.contains("Sessions: 2"))
        #expect(report.contains("Weighted average app CPU: 15.00%"))
        #expect(report.contains("Sample gaps: 0"))
        #expect(report.contains("Disk read delta: 10 bytes"))
        #expect(report.contains("observed CPU time 300 ms"))
        #expect(report.contains("Mixed samples excluded from state rows: 1"))
        #expect(report.contains("Multiple recorder sessions"))
    }

    @Test("marks truncated and invalid lines and incomplete operations")
    func malformedAndIncompleteData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostic-report-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("session-c.jsonl")
        let valid = line(session: "C", sequence: 1, mono: 1, event: "operation", fields: ["operation": "render", "phase": "begin", "intervalID": 7])
        let gap = line(session: "C", sequence: 4, mono: 4, event: "resourceSample", fields: ["sampleGap": true, "sampleAvailable": false, "errorCategory": "samplingFailed"])
        try (valid + gap + "{\"sessionUUID\":\"C\",\"sequence\":2").write(to: file, atomically: true, encoding: .utf8)

        let report = try DiagnosticReport.render(logURLs: [file])
        #expect(report.contains("Corrupt last lines: 1"))
        #expect(report.contains("Incomplete intervals: 1"))
        #expect(report.contains("Sample gaps: 1"))
        #expect(report.contains("unavailable samples 1"))
        #expect(report.contains("No complete operation intervals"))
    }

    private func line(session: String, sequence: Int, mono: Int, event: String, fields: [String: Any]) -> String {
        let object: [String: Any] = ["sessionUUID": session, "sequence": sequence, "wallTime": "2026-01-01T00:00:00Z", "monotonicNanoseconds": mono, "event": event, "fields": fields]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private func write(lines: [String], to url: URL) throws {
        try lines.joined().write(to: url, atomically: true, encoding: .utf8)
    }
}
