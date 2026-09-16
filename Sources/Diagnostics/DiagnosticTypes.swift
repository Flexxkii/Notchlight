import Foundation
import Darwin
import os.signpost

public enum DiagnosticValue: Sendable, Codable, Equatable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int64.self) { self = .int(value); return }
        if let value = try? container.decode(Double.self) { self = .double(value); return }
        self = .string(try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value):
            if value.isFinite { try container.encode(value) } else { try container.encodeNil() }
        case .bool(let value): try container.encode(value)
        }
    }
}

public enum DiagnosticEventName: String, Sendable, Codable {
    case lifecycle
    case resourceSample
    case operation
    case helperSample
    case helperLifecycle
    case failure
    case context
    case counters
}

public enum DiagnosticOperation: String, Sendable, Codable {
    case activityRead
    case databaseDiscovery
    case databaseQuery
    case usageRefresh
    case rpcInitialize
    case rpcAccount
    case rpcLimits
}

public enum DiagnosticOutcome: String, Sendable, Codable {
    case success
    case failed
    case cancelled
    case timedOut
    case unavailable
}

public enum DiagnosticCounter: String, Sendable, Codable {
    case mouse
    case overlayUpdate
    case render
}

public struct DiagnosticStatus: Sendable, Equatable {
    public let isEnabled: Bool
    public let errorCategory: String?
    public let directory: URL

    public init(isEnabled: Bool, errorCategory: String?, directory: URL) {
        self.isEnabled = isEnabled
        self.errorCategory = errorCategory
        self.directory = directory
    }
}

public struct DiagnosticInterval: Sendable {
    let id: UInt64
    let operation: DiagnosticOperation
    let signpostState: OSSignpostIntervalState?
    let startMonotonicNanoseconds: UInt64
    let startWallNanoseconds: UInt64
}

public struct ProcessResourceSnapshot: Sendable, Equatable {
    public let processStartNanoseconds: UInt64
    public let userTimeNanoseconds: UInt64
    public let systemTimeNanoseconds: UInt64
    public let physicalFootprintBytes: UInt64
    public let residentBytes: UInt64
    public let diskReadBytes: UInt64
    public let diskWriteBytes: UInt64
    public let pageins: UInt64
    public let packageIdleWakeups: UInt64
    public let interruptWakeups: UInt64

    public init(processStartNanoseconds: UInt64, userTimeNanoseconds: UInt64,
                systemTimeNanoseconds: UInt64, physicalFootprintBytes: UInt64,
                residentBytes: UInt64, diskReadBytes: UInt64, diskWriteBytes: UInt64,
                pageins: UInt64, packageIdleWakeups: UInt64, interruptWakeups: UInt64) {
        self.processStartNanoseconds = processStartNanoseconds
        self.userTimeNanoseconds = userTimeNanoseconds
        self.systemTimeNanoseconds = systemTimeNanoseconds
        self.physicalFootprintBytes = physicalFootprintBytes
        self.residentBytes = residentBytes
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.pageins = pageins
        self.packageIdleWakeups = packageIdleWakeups
        self.interruptWakeups = interruptWakeups
    }

    public var processStartIdentity: UInt64 { processStartNanoseconds }

    public static func read(pid: Int32 = Int32(getpid())) throws -> ProcessResourceSnapshot {
        let storage = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<rusage_info_v4>.stride,
                                                       alignment: MemoryLayout<rusage_info_v4>.alignment)
        defer { storage.deallocate() }
        // rusage_info_t is imported as a pointer-shaped typedef, while the
        // API writes a complete rusage_info_v4 into the supplied storage.
        let result = proc_pid_rusage(pid, RUSAGE_INFO_V4,
                                     storage.assumingMemoryBound(to: rusage_info_t?.self))
        guard result == 0 else {
            throw NSError(domain: "Diagnostics", code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "proc_pid_rusage failed"
            ])
        }
        let usage = storage.assumingMemoryBound(to: rusage_info_v4.self).pointee
        return ProcessResourceSnapshot(
            processStartNanoseconds: diagnosticsMachTicksToNanoseconds(usage.ri_proc_start_abstime),
            // XNU's recount fields are Mach absolute-time ticks (the
            // `*_mach` counters), despite the otherwise unit-less rusage
            // struct. Convert before exposing the nanosecond API used by the
            // recorder's wall-time CPU percentage calculation.
            userTimeNanoseconds: diagnosticsMachTicksToNanoseconds(usage.ri_user_time),
            systemTimeNanoseconds: diagnosticsMachTicksToNanoseconds(usage.ri_system_time),
            physicalFootprintBytes: usage.ri_phys_footprint,
            residentBytes: usage.ri_resident_size,
            diskReadBytes: usage.ri_diskio_bytesread,
            diskWriteBytes: usage.ri_diskio_byteswritten,
            pageins: usage.ri_pageins,
            packageIdleWakeups: usage.ri_pkg_idle_wkups,
            interruptWakeups: usage.ri_interrupt_wkups
        )
    }
}


internal func diagnosticsMachTicksToNanoseconds(_ ticks: UInt64) -> UInt64 {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    return diagnosticsMachTicksToNanoseconds(ticks, numer: timebase.numer, denom: timebase.denom)
}

/// Converts Mach absolute-time ticks without overflowing the intermediate
/// product. This overload is injectable in tests so the arithmetic is
/// exercised independently of the host's timebase.
internal func diagnosticsMachTicksToNanoseconds(_ ticks: UInt64, numer: UInt32, denom: UInt32) -> UInt64 {
    guard denom != 0 else { return .max }
    let denominator = UInt64(denom)
    let whole = ticks / denominator
    let remainder = ticks % denominator
    let wholeResult = whole.multipliedReportingOverflow(by: UInt64(numer))
    if wholeResult.overflow { return .max }
    // remainder < denom <= UInt32.max, so this product is always representable.
    let fractional = (remainder * UInt64(numer)) / denominator
    let result = wholeResult.partialValue.addingReportingOverflow(fractional)
    return result.overflow ? .max : result.partialValue
}
