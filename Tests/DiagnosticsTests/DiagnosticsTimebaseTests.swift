import Darwin
import Foundation
import Testing
@testable import Diagnostics

@Suite("Diagnostics timebase")
struct DiagnosticsTimebaseTests {
    @Test("Mach tick conversion handles quotient and remainder")
    func convertsInjectedTimebase() {
        #expect(diagnosticsMachTicksToNanoseconds(3, numer: 125, denom: 3) == 125)
        #expect(diagnosticsMachTicksToNanoseconds(4, numer: 125, denom: 3) == 166)
        #expect(diagnosticsMachTicksToNanoseconds(12_000_000, numer: 125, denom: 3) == 500_000_000)
    }

    @Test("Mach tick conversion saturates instead of overflowing")
    func conversionSaturates() {
        #expect(diagnosticsMachTicksToNanoseconds(.max, numer: .max, denom: 1) == .max)
        #expect(diagnosticsMachTicksToNanoseconds(.max, numer: 125, denom: 3) == .max)
        #expect(diagnosticsMachTicksToNanoseconds(10, numer: 1, denom: 0) == .max)
    }

    @Test("live proc rusage CPU time is nanoseconds")
    func liveCPUTimeMatchesGetrusage() throws {
        let beforeSnapshot = try ProcessResourceSnapshot.read()
        let beforeUsage = try #require(getrusageCPUTimeNanoseconds())
        let start = DispatchTime.now().uptimeNanoseconds
        var value: UInt64 = 0
        while DispatchTime.now().uptimeNanoseconds - start < 200_000_000 {
            value = value &* 1_664_525 &+ 1_013_904_223
        }
        _ = value
        let afterSnapshot = try ProcessResourceSnapshot.read()
        let afterUsage = try #require(getrusageCPUTimeNanoseconds())
        let snapshotDelta = (afterSnapshot.userTimeNanoseconds - beforeSnapshot.userTimeNanoseconds) &+
            (afterSnapshot.systemTimeNanoseconds - beforeSnapshot.systemTimeNanoseconds)
        let usageDelta = afterUsage - beforeUsage

        #expect(usageDelta > 10_000_000)
        let difference = snapshotDelta >= usageDelta ? snapshotDelta - usageDelta : usageDelta - snapshotDelta
        #expect(difference < 100_000_000)
    }

    private func getrusageCPUTimeNanoseconds() -> UInt64? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        let userSeconds = UInt64(max(0, usage.ru_utime.tv_sec))
        let userMicros = UInt64(max(0, usage.ru_utime.tv_usec))
        let systemSeconds = UInt64(max(0, usage.ru_stime.tv_sec))
        let systemMicros = UInt64(max(0, usage.ru_stime.tv_usec))
        return userSeconds &* 1_000_000_000 &+ userMicros &* 1_000 &+
            systemSeconds &* 1_000_000_000 &+ systemMicros &* 1_000
    }
}
