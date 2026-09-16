import Foundation
import Darwin

/// Stable, privacy-reviewed process and host metadata used in the session
/// lifecycle event. No filesystem path or application payload is returned.
enum DiagnosticEnvironment {
    static func fields() -> [String: DiagnosticValue] {
        let info = Bundle.main.infoDictionary ?? [:]
        let processInfo = ProcessInfo.processInfo
        let uuid = loadedMachOUUID() ?? "unavailable"
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        return [
            "version": .string((info["CFBundleShortVersionString"] as? String) ?? "unknown"),
            "build": .string((info["CFBundleVersion"] as? String) ?? "unknown"),
            "buildConfiguration": .string(configuration),
            "executableUUID": .string(uuid),
            "machUUID": .string(uuid),
            "os": .string(processInfo.operatingSystemVersionString),
            "logicalCPUCount": .int(Int64(processInfo.processorCount)),
            "physicalMemoryBytes": .int(Int64(clamping: processInfo.physicalMemory)),
            "thermal": .string(thermalState(processInfo.thermalState)),
            "lowPower": .bool(processInfo.isLowPowerModeEnabled)
        ]
    }

    private static func thermalState(_ value: ProcessInfo.ThermalState) -> String {
        switch value {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func loadedMachOUUID() -> String? {
        guard let header = _dyld_get_image_header(0) else { return nil }
        let raw = UnsafeRawPointer(header)
        let magic = raw.load(as: UInt32.self)
        guard magic == MH_MAGIC_64 else { return nil }
        let commandCount = Int(raw.load(fromByteOffset: 16, as: UInt32.self))
        let commandBytes = Int(raw.load(fromByteOffset: 20, as: UInt32.self))
        guard commandCount >= 0, commandBytes >= 0, commandBytes <= 16 * 1024 * 1024 else { return nil }
        var offset = MemoryLayout<mach_header_64>.size
        for _ in 0..<commandCount {
            guard offset + 8 <= MemoryLayout<mach_header_64>.size + commandBytes else { return nil }
            let command = raw.load(fromByteOffset: offset, as: UInt32.self)
            let size = Int(raw.load(fromByteOffset: offset + 4, as: UInt32.self))
            guard size >= 8, offset + size <= MemoryLayout<mach_header_64>.size + commandBytes else { return nil }
            if command == UInt32(LC_UUID), size >= 24 {
                let uuid = raw.advanced(by: offset + 8).assumingMemoryBound(to: UInt8.self)
                return (0..<16).map { String(format: "%02x", uuid[$0]) }.joined()
            }
            offset += size
        }
        return nil
    }
}
