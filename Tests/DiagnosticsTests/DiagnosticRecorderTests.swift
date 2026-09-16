import Foundation
import Testing
@testable import Diagnostics

@Suite("Diagnostics")
struct DiagnosticRecorderTests {
    final class Box: @unchecked Sendable {
        var tick: UInt64 = 1
        var wall = Date(timeIntervalSince1970: 100)
        var mono: UInt64 = 1_000_000_000
    }

    @Test("resource snapshot can be read")
    func resourceSnapshot() throws {
        let snapshot = try ProcessResourceSnapshot.read()
        #expect(snapshot.processStartNanoseconds > 0)
        #expect(snapshot.userTimeNanoseconds + snapshot.systemTimeNanoseconds >= 0)
    }

    @Test("recorder writes JSONL and preserves context across disable")
    func writesAndPreservesContext() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let box = Box()
        let recorder = DiagnosticRecorder(testDirectory: directory, sampler: {
            box.tick += 1
            return ProcessResourceSnapshot(processStartNanoseconds: 1, userTimeNanoseconds: box.tick,
                                            systemTimeNanoseconds: 0, physicalFootprintBytes: 10,
                                            residentBytes: 20, diskReadBytes: 3, diskWriteBytes: 4,
                                            pageins: 5, packageIdleWakeups: 6, interruptWakeups: 7)
        }, wallClock: { box.wall }, monotonicClock: { box.tick * 1_000_000_000 })
        recorder.updateContext(["codex_working": .bool(true)])
        recorder.setEnabled(false)
        recorder.setEnabled(true)
        recorder.record(.failure, fields: ["errorCategory": .string("test")])
        recorder.flush()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let logs = files.filter { $0.pathExtension == "jsonl" }
        let contents = try logs.map { try String(contentsOf: $0) }.joined(separator: "\n")
        #expect(contents.contains("codex_working"))
        #expect(contents.contains("sessionStart"))
        #expect(contents.contains("\"event\":\"failure\""))
        recorder.shutdown()
    }

    @Test("export contains metadata and report")
    func exportArchive() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-\(UUID().uuidString)")
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: archive) }
        let recorder = DiagnosticRecorder(directory: directory)
        recorder.record(.context, fields: ["active_task_count": .int(1)])
        recorder.flush()
        try recorder.export(to: archive)
        #expect(FileManager.default.fileExists(atPath: archive.path))
        #expect((try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.intValue ?? 0 > 0)
        let extraction = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-extracted-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: extraction) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, extraction.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let listing = Process()
        let listingOutput = Pipe()
        listing.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        listing.arguments = ["-Z", "-1", archive.path]
        listing.standardOutput = listingOutput
        try listing.run()
        let entries = String(decoding: listingOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        listing.waitUntilExit()
        #expect(listing.terminationStatus == 0)
        #expect(!entries.contains("/._"))
        #expect(!entries.contains("__MACOSX"))
        let extractedFiles = (FileManager.default.enumerator(at: extraction, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }) ?? []
        #expect(extractedFiles.contains { $0.lastPathComponent == "metadata.json" })
        #expect(extractedFiles.contains { $0.lastPathComponent == "report.md" })
        recorder.shutdown()
    }

    @Test("sampling failures are recorded and reflected in status")
    func samplerFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = DiagnosticRecorder(testDirectory: directory, sampler: {
            throw NSError(domain: "test", code: 1)
        }, wallClock: { Date(timeIntervalSince1970: 100) }, monotonicClock: { 1_000_000_000 })
        recorder.sampleNowForTesting()
        recorder.flush()
        #expect(recorder.status.errorCategory == "samplingFailed")
        let log = try #require(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "jsonl" }))
        #expect(try String(contentsOf: log).contains("samplingFailed"))
        recorder.shutdown()
    }

    @Test("CPU percentage uses elapsed wall time with one core at 100 percent")
    func cpuArithmetic() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let box = Box()
        let recorder = DiagnosticRecorder(testDirectory: directory, sampler: {
            ProcessResourceSnapshot(processStartNanoseconds: 1, userTimeNanoseconds: box.tick,
                                    systemTimeNanoseconds: 0, physicalFootprintBytes: 10,
                                    residentBytes: 20, diskReadBytes: 3, diskWriteBytes: 4,
                                    pageins: 5, packageIdleWakeups: 6, interruptWakeups: 7)
        }, wallClock: { box.wall }, monotonicClock: { box.mono })
        box.tick = 2_000_000_001
        box.mono = 3_000_000_000
        box.wall = Date(timeIntervalSince1970: 102)
        recorder.sampleNowForTesting()
        recorder.flush()
        let records = try records(in: directory)
        let sample = try #require(records.first { ($0["event"] as? String) == "resourceSample" && (($0["fields"] as? [String: Any])?["cpuPercent"] as? NSNumber) != nil })
        let fields = try #require(sample["fields"] as? [String: Any])
        #expect((fields["cpuPercent"] as? NSNumber)?.doubleValue == 100)
        #expect((fields["elapsedNanoseconds"] as? NSNumber)?.int64Value == 2_000_000_000)
        #expect((fields["cpuDeltaNanoseconds"] as? NSNumber)?.int64Value == 2_000_000_000)
        recorder.shutdown()
    }

    @Test("context updates are diffed and privacy filtering removes paths and payload-like values")
    func contextDiffAndPrivacy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = DiagnosticRecorder(testDirectory: directory, sampler: {
            ProcessResourceSnapshot(processStartNanoseconds: 1, userTimeNanoseconds: 1,
                                    systemTimeNanoseconds: 0, physicalFootprintBytes: 1,
                                    residentBytes: 1, diskReadBytes: 0, diskWriteBytes: 0,
                                    pageins: 0, packageIdleWakeups: 0, interruptWakeups: 0)
        }, wallClock: { Date(timeIntervalSince1970: 100) }, monotonicClock: { 1_000_000_000 })
        recorder.updateContext(["codex_working": .bool(true), "path": .string("/private/secret"), "message": .string("payload")])
        recorder.updateContext(["codex_working": .bool(true)])
        recorder.flush()
        let records = try records(in: directory)
        let contexts = records.filter { ($0["event"] as? String) == DiagnosticEventName.context.rawValue }
        #expect(contexts.count == 1)
        let serialized = try String(contentsOf: logURL(in: directory))
        #expect(!serialized.contains("/private/secret"))
        #expect(!serialized.contains("payload"))
        recorder.shutdown()
    }

    @Test("pending diagnostics stay within configured memory budget while writer is blocked")
    func boundedPendingBuffer() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = DiagnosticConfiguration()
        config.maximumPendingBytes = 2_048
        let recorder = DiagnosticRecorder(testDirectory: directory, sampler: {
            ProcessResourceSnapshot(processStartNanoseconds: 1, userTimeNanoseconds: 1,
                                    systemTimeNanoseconds: 0, physicalFootprintBytes: 1,
                                    residentBytes: 1, diskReadBytes: 0, diskWriteBytes: 0,
                                    pageins: 0, packageIdleWakeups: 0, interruptWakeups: 0)
        }, wallClock: { Date(timeIntervalSince1970: 100) }, monotonicClock: { 1_000_000_000 }, configuration: config)
        let gate = DispatchSemaphore(value: 0)
        recorder.blockWriterForTesting { _ = gate.wait(timeout: .distantFuture) }
        let text = String(repeating: "x", count: 220)
        for _ in 0..<50 { recorder.record(.failure, fields: ["category": .string(text)]) }
        #expect(recorder.pendingByteCountForTesting <= config.maximumPendingBytes)
        gate.signal()
        recorder.flush()
        let output = try String(contentsOf: logURL(in: directory))
        #expect(output.contains("eventsDropped"))
        #expect(output.contains("droppedCount"))
        recorder.shutdown()
    }

    @Test("coalesces a burst of baseline resets into one marker")
    func coalescedBaselineResets() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = DiagnosticRecorder(testDirectory: directory, sampler: {
            ProcessResourceSnapshot(processStartNanoseconds: 1, userTimeNanoseconds: 1, systemTimeNanoseconds: 0,
                                    physicalFootprintBytes: 1, residentBytes: 1, diskReadBytes: 0, diskWriteBytes: 0,
                                    pageins: 0, packageIdleWakeups: 0, interruptWakeups: 0)
        }, wallClock: { Date(timeIntervalSince1970: 100) }, monotonicClock: { 1_000_000_000 })
        let gate = DispatchSemaphore(value: 0)
        recorder.blockWriterForTesting { _ = gate.wait(timeout: .distantFuture) }
        for _ in 0..<1_000 { recorder.resetBaseline(reason: "burst") }
        gate.signal()
        recorder.flush()
        let contents = try String(contentsOf: logURL(in: directory))
        #expect(contents.components(separatedBy: "baselineReset").count - 1 == 1)
        recorder.shutdown()
    }

    @Test("counter rollback resets baseline without emitting invalid deltas, then recovers")
    func counterRollbackRecovery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let box = Box()
        let recorder = DiagnosticRecorder(testDirectory: directory, sampler: {
            ProcessResourceSnapshot(processStartNanoseconds: 1, userTimeNanoseconds: box.tick,
                                    systemTimeNanoseconds: 0, physicalFootprintBytes: box.tick,
                                    residentBytes: box.tick, diskReadBytes: box.tick, diskWriteBytes: box.tick,
                                    pageins: box.tick, packageIdleWakeups: box.tick, interruptWakeups: box.tick)
        }, wallClock: { box.wall }, monotonicClock: { box.mono })
        box.tick = 0; box.mono += 1_000_000_000; box.wall = box.wall.addingTimeInterval(1)
        recorder.sampleNowForTesting()
        recorder.flush()
        box.tick = 5; box.mono += 1_000_000_000; box.wall = box.wall.addingTimeInterval(1)
        recorder.sampleNowForTesting()
        recorder.flush()
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
            .map { try String(contentsOf: $0) }
            .joined(separator: "\n")
        #expect(contents.contains("counterDiscontinuity"))
        #expect(contents.contains("cpuDeltaNanoseconds"))
        recorder.shutdown()
    }

    @Test("retains valid raw metrics after sampling failure recovery")
    func samplingFailureRecovery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let box = Box()
        let recorder = DiagnosticRecorder(testDirectory: directory, sampler: {
            if box.tick == 1 { throw NSError(domain: "test", code: 1) }
            return ProcessResourceSnapshot(processStartNanoseconds: 1, userTimeNanoseconds: box.tick,
                                            systemTimeNanoseconds: 0, physicalFootprintBytes: 2, residentBytes: 2,
                                            diskReadBytes: 1, diskWriteBytes: 1, pageins: 1, packageIdleWakeups: 1,
                                            interruptWakeups: 1)
        }, wallClock: { box.wall }, monotonicClock: { box.mono })
        box.tick = 2; box.mono += 1_000_000_000
        recorder.sampleNowForTesting()
        recorder.flush()
        let fields = try records(in: directory).compactMap { $0["fields"] as? [String: Any] }
        #expect(fields.contains { ($0["sampleAvailable"] as? NSNumber)?.boolValue == false })
        #expect(fields.contains { ($0["physicalFootprintBytes"] as? NSNumber)?.int64Value == 2 })
        recorder.shutdown()
    }

    @Test("age retention removes old session logs but leaves unrelated files")
    func ageRetention() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = directory.appendingPathComponent("session-old.jsonl")
        try "old\n".write(to: old, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: old.path)
        let unrelated = directory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)
        var config = DiagnosticConfiguration(); config.maximumAge = 1
        let recorder = DiagnosticRecorder(testDirectory: directory, sampler: {
            ProcessResourceSnapshot(processStartNanoseconds: 1, userTimeNanoseconds: 1, systemTimeNanoseconds: 0,
                                    physicalFootprintBytes: 1, residentBytes: 1, diskReadBytes: 0, diskWriteBytes: 0,
                                    pageins: 0, packageIdleWakeups: 0, interruptWakeups: 0)
        }, wallClock: { Date(timeIntervalSince1970: 100) }, monotonicClock: { 1_000_000_000 }, configuration: config)
        recorder.flush()
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        recorder.shutdown()
    }

    @Test("small configured files rotate and retention remains bounded")
    func rotationAndRetention() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = DiagnosticConfiguration()
        config.maximumPendingBytes = 64 * 1_024
        config.maximumFileBytes = 512
        config.maximumTotalBytes = 2_048
        config.rotationAge = 3_600
        let recorder = DiagnosticRecorder(testDirectory: directory, sampler: {
            ProcessResourceSnapshot(processStartNanoseconds: 1, userTimeNanoseconds: 1,
                                    systemTimeNanoseconds: 0, physicalFootprintBytes: 1,
                                    residentBytes: 1, diskReadBytes: 0, diskWriteBytes: 0,
                                    pageins: 0, packageIdleWakeups: 0, interruptWakeups: 0)
        }, wallClock: { Date(timeIntervalSince1970: 100) }, monotonicClock: { 1_000_000_000 }, configuration: config)
        for _ in 0..<50 { recorder.record(.failure, fields: ["category": .string(String(repeating: "r", count: 100))]) }
        recorder.flush()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]).filter { $0.pathExtension == "jsonl" }
        #expect(files.count > 1)
        let total = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        #expect(total <= config.maximumTotalBytes + config.maximumFileBytes)
        recorder.shutdown()
    }

    @Test("baseline reset keeps raw counters and emits a discontinuity marker")
    func baselineReset() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let box = Box()
        let recorder = DiagnosticRecorder(testDirectory: directory, sampler: {
            box.tick += 1
            return ProcessResourceSnapshot(processStartNanoseconds: 1, userTimeNanoseconds: box.tick,
                                            systemTimeNanoseconds: 0, physicalFootprintBytes: 10,
                                            residentBytes: 20, diskReadBytes: 3, diskWriteBytes: 4,
                                            pageins: 5, packageIdleWakeups: 6, interruptWakeups: 7)
        }, wallClock: { box.wall }, monotonicClock: { box.mono })
        recorder.sampleNowForTesting()
        box.tick += 10; box.mono += 2_000_000_000; box.wall = box.wall.addingTimeInterval(2)
        recorder.sampleNowForTesting()
        recorder.resetBaseline(reason: "test sleep/wake")
        recorder.flush()
        let log = try #require(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "jsonl" }))
        let contents = try String(contentsOf: log)
        #expect(contents.contains("cpuDeltaNanoseconds"))
        #expect(contents.contains("baselineReset"))
        recorder.shutdown()
    }

    @Test("environment UUID is a bounded hexadecimal Mach-O identity")
    func environmentIdentity() {
        guard case .string(let value) = DiagnosticEnvironment.fields()["executableUUID"] else {
            Issue.record("executableUUID was not emitted")
            return
        }
        if value != "unavailable" {
            #expect(value.count == 32)
            #expect(value.allSatisfy { "0123456789abcdef".contains($0) })
        }
    }

    @Test("a context revision change marks the following sample as mixed state")
    func mixedContextSample() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let box = Box()
        let recorder = DiagnosticRecorder(testDirectory: directory, sampler: {
            ProcessResourceSnapshot(processStartNanoseconds: 1, userTimeNanoseconds: box.tick,
                                    systemTimeNanoseconds: 0, physicalFootprintBytes: 1,
                                    residentBytes: 1, diskReadBytes: 0, diskWriteBytes: 0,
                                    pageins: 0, packageIdleWakeups: 0, interruptWakeups: 0)
        }, wallClock: { box.wall }, monotonicClock: { box.mono })
        recorder.updateContext(["codex_working": .bool(true)])
        box.tick += 2_000_000_000; box.mono += 2_000_000_000; box.wall = box.wall.addingTimeInterval(2)
        recorder.sampleNowForTesting()
        recorder.flush()
        let samples = try records(in: directory).filter { ($0["event"] as? String) == DiagnosticEventName.resourceSample.rawValue }
        let fields = try #require(samples.last?["fields"] as? [String: Any])
        #expect((fields["mixedState"] as? NSNumber)?.boolValue == true)
        recorder.shutdown()
    }

    private func logURL(in directory: URL) throws -> URL {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "jsonl" }).unwrap(or: CocoaError(.fileNoSuchFile))
    }

    private func records(in directory: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: try logURL(in: directory))
        return try data.split(separator: 10).compactMap { try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }
}

private extension Optional {
    func unwrap(or error: Error) throws -> Wrapped {
        guard let value = self else { throw error }
        return value
    }
}
