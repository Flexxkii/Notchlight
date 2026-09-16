import Foundation
import Testing
@testable import Diagnostics

@Suite("Diagnostics writer failures")
struct WriterFailureTests {
    @Test("failed session state does not pollute recovery session")
    func failedSessionIsolation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration = DiagnosticConfiguration()
        configuration.maximumPendingBytes = 16_384
        configuration.maximumFileBytes = 4_096
        configuration.rotationAge = 0
        let recorder = DiagnosticRecorder(testDirectory: directory, sampler: {
            ProcessResourceSnapshot(processStartNanoseconds: 1, userTimeNanoseconds: 1,
                                    systemTimeNanoseconds: 0, physicalFootprintBytes: 1,
                                    residentBytes: 1, diskReadBytes: 0, diskWriteBytes: 0,
                                    pageins: 0, packageIdleWakeups: 0, interruptWakeups: 0)
        }, wallClock: { Date(timeIntervalSince1970: 100) }, monotonicClock: { 1_000_000_000 }, configuration: configuration)

        recorder.aggregate(.render, durationNanoseconds: 50, count: 3)
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        recorder.blockWriterForTesting {
            started.signal()
            _ = release.wait(timeout: .distantFuture)
            let fm = FileManager.default
            for item in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.removeItem(at: item)
            }
            try? fm.removeItem(at: directory)
            _ = fm.createFile(atPath: directory.path, contents: Data("obstructed".utf8))
        }
        #expect(started.wait(timeout: .now() + 2) == .success)
        for _ in 0..<50 {
            recorder.record(.failure, fields: ["category": .string("write-test")])
        }
        release.signal()
        recorder.flush()
        #expect(recorder.status.errorCategory == "writeFailed")
        #expect(!recorder.isEnabled)

        let fm = FileManager.default
        try fm.removeItem(at: directory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        recorder.setEnabled(true)
        recorder.flush()
        #expect(recorder.isEnabled)
        let logs = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
        let contents = try logs.map { try String(contentsOf: $0) }.joined(separator: "\n")
        #expect(!contents.contains("eventsDropped"))
        #expect(!contents.contains("\"event\":\"counters\""))
        recorder.shutdown()
    }
}
