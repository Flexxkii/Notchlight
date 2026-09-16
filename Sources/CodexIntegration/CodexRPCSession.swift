import Foundation
import Darwin
import Diagnostics

final class CodexRPCSession: @unchecked Sendable {
    private static let timeout: TimeInterval = 15
    private let cancellation: CodexCancellationToken
    private let diagnostics: DiagnosticRecorder
    private let executableOverride: URL?
    private let timeoutOverride: TimeInterval?
    private var lastHelperSample = Date.distantPast

    init(cancellation: CodexCancellationToken, diagnostics: DiagnosticRecorder = .disabled, executable: URL? = nil, timeout: TimeInterval? = nil) {
        self.cancellation = cancellation
        self.diagnostics = diagnostics
        self.executableOverride = executable
        self.timeoutOverride = timeout
    }

    func readSnapshot() throws -> CodexUsageSnapshot {
        if cancellation.isCancelled { throw CodexUsageError.cancelled }
        guard let executable = executableOverride ?? CodexExecutable.locate() else { throw CodexUsageError.executableUnavailable }
        let launchID = UUID().uuidString
        lastHelperSample = .distantPast
        let process = Process()
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        let collector = CodexRPCLineCollector(output: output, error: error)
        collector.start()
        defer {
            collector.stop()
            terminate(process)
            input.fileHandleForWriting.closeFile()
            output.fileHandleForReading.closeFile()
            error.fileHandleForReading.closeFile()
        }
        do { try process.run() } catch {
            diagnostics.record(.helperLifecycle, fields: [
                "phase": .string("launch"), "outcome": .string("failed")
            ])
            throw CodexUsageError.launchFailed
        }
        let pid = process.processIdentifier
        let startIdentity = sampleHelper(process: process, launchID: launchID, pid: pid, phase: "launched")
        lastHelperSample = Date()
        diagnostics.record(.helperLifecycle, fields: [
            "phase": .string("launched"), "launchID": .string(launchID),
            "pid": .int(Int64(pid)), "startIdentity": startIdentity.map { .int(Int64(clamping: $0)) } ?? .string("unknown")
        ])
        defer {
            _ = sampleHelper(process: process, launchID: launchID, pid: pid, phase: "pretermination", expectedStartIdentity: startIdentity)
            diagnostics.record(.helperLifecycle, fields: [
                "phase": .string("pretermination"), "launchID": .string(launchID),
                "pid": .int(Int64(pid)), "startIdentity": startIdentity.map { .int(Int64(clamping: $0)) } ?? .string("unknown")
            ])
        }
        let deadline = Date().addingTimeInterval(timeoutOverride ?? Self.timeout)
        _ = try request(["method": "initialize", "params": ["clientInfo": ["name": "notchlight", "title": "Notchlight", "version": "1.1.0"], "capabilities": ["experimentalApi": false]]], operation: .rpcInitialize, process: process, input: input, collector: collector, deadline: deadline, launchID: launchID, pid: pid, expectedStartIdentity: startIdentity)
        try send(["method": "initialized", "params": [:]], input: input)
        let account = try request(["method": "account/read", "params": ["refreshToken": false]], operation: .rpcAccount, process: process, input: input, collector: collector, deadline: deadline, launchID: launchID, pid: pid, expectedStartIdentity: startIdentity)
        guard let accountInfo = account["account"] as? [String: Any] else { throw CodexUsageError.signInRequired }
        guard accountInfo["type"] as? String == "chatgpt" else { throw CodexUsageError.incompatibleAccount }
        let limits = try request(["method": "account/rateLimits/read", "params": [:]], operation: .rpcLimits, process: process, input: input, collector: collector, deadline: deadline, launchID: launchID, pid: pid, expectedStartIdentity: startIdentity)
        return try CodexUsageParser.snapshot(from: limits, sampledAt: Date())
    }

    private func request(_ record: [String: Any], operation: DiagnosticOperation, process: Process, input: Pipe, collector: CodexRPCLineCollector, deadline: Date, launchID: String, pid: Int32, expectedStartIdentity: UInt64?) throws -> [String: Any] {
        let interval = diagnostics.beginInterval(operation)
        let initialBytes = collector.receivedBytes
        var outcome: DiagnosticOutcome = .failed
        defer {
            diagnostics.endInterval(interval, outcome: outcome, fields: ["rpcBytesReceived": .int(Int64(max(0, collector.receivedBytes - initialBytes)))])
        }
        do {
            let id = collector.nextID()
            var request = record; request["id"] = id
            try send(request, input: input)
            while Date() < deadline {
                if cancellation.isCancelled { throw CodexUsageError.cancelled }
                if !process.isRunning { throw CodexUsageError.protocolFailure }
                if collector.failed { throw CodexUsageError.protocolFailure }
                if Date().timeIntervalSince(lastHelperSample) >= 0.25 {
                    _ = sampleHelper(process: process, launchID: launchID, pid: pid, phase: "poll", expectedStartIdentity: expectedStartIdentity)
                    lastHelperSample = Date()
                }
                if let response = collector.take(id: id) {
                    guard let result = response["result"] as? [String: Any], response["error"] == nil else { throw CodexUsageError.protocolFailure }
                    outcome = .success
                    return result
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
            throw CodexUsageError.timedOut
        } catch let error as CodexUsageError {
            switch error {
            case .cancelled: outcome = .cancelled
            case .timedOut: outcome = .timedOut
            default: outcome = .failed
            }
            diagnostics.record(.failure, fields: [
                "operation": .string(String(describing: operation)),
                "category": .string(failureCategory(error))
            ])
            throw error
        }
    }

    private func failureCategory(_ error: CodexUsageError) -> String {
        switch error {
        case .cancelled: "cancelled"
        case .timedOut: "timeout"
        case .protocolFailure: "protocol"
        case .invalidResponse: "invalid_response"
        case .signInRequired: "sign_in_required"
        case .incompatibleAccount: "incompatible_account"
        case .executableUnavailable: "executable_unavailable"
        case .launchFailed: "launch_failed"
        }
    }

    private func send(_ record: [String: Any], input: Pipe) throws {
        guard JSONSerialization.isValidJSONObject(record) else { throw CodexUsageError.protocolFailure }
        let data = try JSONSerialization.data(withJSONObject: record)
        do {
            try input.fileHandleForWriting.write(contentsOf: data + Data([10]))
        } catch {
            throw CodexUsageError.protocolFailure
        }
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    @discardableResult
    private func sampleHelper(process: Process, launchID: String, pid: Int32, phase: String, expectedStartIdentity: UInt64? = nil) -> UInt64? {
        guard diagnostics.isEnabled else { return nil }
        guard let snapshot = try? ProcessResourceSnapshot.read(pid: pid) else {
            diagnostics.record(.helperSample, fields: ["phase": .string(phase), "launchID": .string(launchID), "pid": .int(Int64(pid)), "sampleAvailable": .bool(false)])
            return nil
        }
        guard expectedStartIdentity == nil || expectedStartIdentity == snapshot.processStartIdentity else {
            diagnostics.record(.failure, fields: ["category": .string("helper_identity_changed"), "phase": .string(phase)])
            return nil
        }
        diagnostics.record(.helperSample, fields: [
            "phase": .string(phase), "launchID": .string(launchID), "pid": .int(Int64(pid)),
            "sampleAvailable": .bool(true), "partial": .bool(true),
            "startIdentity": .int(Int64(snapshot.processStartIdentity)),
            "userTimeNanoseconds": .int(Int64(snapshot.userTimeNanoseconds)),
            "systemTimeNanoseconds": .int(Int64(snapshot.systemTimeNanoseconds)),
            "physicalFootprintBytes": .int(Int64(snapshot.physicalFootprintBytes)),
            "residentBytes": .int(Int64(snapshot.residentBytes)),
            "diskReadBytes": .int(Int64(snapshot.diskReadBytes)),
            "diskWriteBytes": .int(Int64(snapshot.diskWriteBytes)),
            "pageins": .int(Int64(snapshot.pageins)),
            "packageIdleWakeups": .int(Int64(snapshot.packageIdleWakeups)),
            "interruptWakeups": .int(Int64(snapshot.interruptWakeups))
        ])
        return snapshot.processStartIdentity
    }
}
