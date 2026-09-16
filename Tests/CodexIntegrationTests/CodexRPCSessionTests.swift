import Foundation
import Testing
import Diagnostics
@testable import CodexIntegration

struct CodexRPCSessionTests {
    @Test("RPC session completes a fake helper exchange")
    func success() throws {
        let helper = try FakeCodexHelper(mode: .success)
        defer { helper.remove() }
        let recorder = try makeRecorder()
        let result = try CodexRPCSession(cancellation: CodexCancellationToken(), diagnostics: recorder, executable: helper.url).readSnapshot()
        recorder.flush()
        #expect(result.windows.count == 1)
        #expect(result.windows[0].usedPercent == 12.5)
        let log = try diagnosticText(in: recorder.status.directory)
        #expect(log.contains("rpcInitialize"))
        #expect(log.contains("rpcBytesReceived"))
        #expect(!log.contains(FakeCodexHelper.sentinel))
        let records = try diagnosticRecords(in: recorder.status.directory)
        let launched = try #require(records.first { ($0["event"] as? String) == "helperLifecycle" && (($0["fields"] as? [String: Any])?["phase"] as? String) == "launched" })
        let launchedFields = try #require(launched["fields"] as? [String: Any])
        let launchID = try #require(launchedFields["launchID"] as? String)
        let startIdentity = (launchedFields["startIdentity"] as? NSNumber)?.uint64Value
        let samples = records.compactMap { record -> [String: Any]? in
            guard record["event"] as? String == "helperSample" else { return nil }
            return record["fields"] as? [String: Any]
        }
        #expect(!samples.isEmpty)
        for fields in samples where (fields["sampleAvailable"] as? Bool) == true {
            #expect(fields["launchID"] as? String == launchID)
            #expect((fields["startIdentity"] as? NSNumber)?.uint64Value == startIdentity)
            #expect(fields["partial"] as? Bool == true)
        }
        recorder.shutdown()
        try? FileManager.default.removeItem(at: recorder.status.directory)
    }

    @Test("RPC session reports malformed helper output")
    func protocolFailure() throws {
        let helper = try FakeCodexHelper(mode: .malformed)
        defer { helper.remove() }
        let recorder = try makeRecorder()
        #expect(throws: CodexUsageError.protocolFailure) {
            try CodexRPCSession(cancellation: CodexCancellationToken(), diagnostics: recorder, executable: helper.url).readSnapshot()
        }
        recorder.flush()
        let records = try diagnosticRecords(in: recorder.status.directory)
        #expect(try diagnosticText(in: recorder.status.directory).contains("protocol"))
        let lifecycle = records.filter { $0["event"] as? String == "helperLifecycle" }
        #expect(lifecycle.contains { ($0["fields"] as? [String: Any])?["phase"] as? String == "pretermination" })
        let sampleFields = records.compactMap { $0["event"] as? String == "helperSample" ? $0["fields"] as? [String: Any] : nil }
        #expect(sampleFields.contains { ($0["sampleAvailable"] as? Bool) == false || ($0["partial"] as? Bool) == true })
        recorder.shutdown()
        try? FileManager.default.removeItem(at: recorder.status.directory)
    }

    @Test("RPC session preserves cancellation before launch")
    func cancelled() throws {
        let helper = try FakeCodexHelper(mode: .success)
        defer { helper.remove() }
        let token = CodexCancellationToken()
        token.cancel()
        #expect(throws: CodexUsageError.cancelled) {
            try CodexRPCSession(cancellation: token, executable: helper.url).readSnapshot()
        }
    }

    @Test("RPC session times out when helper never answers")
    func timeout() throws {
        let helper = try FakeCodexHelper(mode: .timeout)
        defer { helper.remove() }
        let recorder = try makeRecorder()
        defer { recorder.shutdown(); try? FileManager.default.removeItem(at: recorder.status.directory) }
        #expect(throws: CodexUsageError.timedOut) {
            try CodexRPCSession(cancellation: CodexCancellationToken(), diagnostics: recorder, executable: helper.url, timeout: 0.1).readSnapshot()
        }
        recorder.flush()
        let log = try diagnosticText(in: recorder.status.directory)
        #expect(log.contains("\"outcome\":\"timedOut\""))
        #expect(log.contains("helperLifecycle"))
        #expect(log.contains("pretermination"))
    }

    @Test("RPC session can be cancelled while waiting for a response")
    func cancellationDuringPendingRPC() throws {
        let helper = try FakeCodexHelper(mode: .timeout)
        defer { helper.remove() }
        let recorder = try makeRecorder()
        defer { recorder.shutdown(); try? FileManager.default.removeItem(at: recorder.status.directory) }
        let token = CodexCancellationToken()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { token.cancel() }
        #expect(throws: CodexUsageError.cancelled) {
            try CodexRPCSession(cancellation: token, diagnostics: recorder, executable: helper.url, timeout: 1).readSnapshot()
        }
        recorder.flush()
        let log = try diagnosticText(in: recorder.status.directory)
        #expect(log.contains("\"outcome\":\"cancelled\""))
        #expect(log.contains("helperSample"))
    }

    private func makeRecorder() throws -> DiagnosticRecorder {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notchlight-diagnostics-test-\(UUID().uuidString)")
        let recorder = DiagnosticRecorder(directory: directory, enabled: true)
        return recorder
    }

    private func diagnosticText(in directory: URL) throws -> String {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try files.filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try String(contentsOf: $0) }.joined()
    }

    private func diagnosticRecords(in directory: URL) throws -> [[String: Any]] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try files.filter { $0.pathExtension == "jsonl" }.flatMap { url in
            try String(contentsOf: url).split(separator: "\n").compactMap {
                try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
        }
    }
}

private struct FakeCodexHelper {
    static let sentinel = "SENTINEL_PRIVATE_PAYLOAD"
    enum Mode { case success, malformed, timeout }
    let url: URL

    init(mode: Mode) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("notchlight-fake-codex-\(UUID().uuidString)")
        let body: String
        switch mode {
        case .success:
            body = "#!/bin/sh\nwhile IFS= read line; do\ncase \"$line\" in\n*'\"method\":\"initialize\"'*) echo '{\"id\":1,\"result\":{},\"payload\":\"SENTINEL_PRIVATE_PAYLOAD\"}' ;;\n*'\"method\":\"account/read\"'*) echo '{\"id\":2,\"result\":{\"account\":{\"type\":\"chatgpt\"}}}' ;;\n*'\"method\":\"account/rateLimits/read\"'*) echo '{\"id\":3,\"result\":{\"rateLimits\":{\"primary\":{\"usedPercent\":12.5,\"windowDurationMins\":300}}}}' ;;\nesac\ndone\n"
        case .malformed:
            body = "#!/bin/sh\necho 'not-json'\n"
        case .timeout:
            body = "#!/bin/sh\nsleep 20\n"
        }
        try Data(body.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}
