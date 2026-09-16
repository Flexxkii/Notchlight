import Foundation
import Testing
@testable import CodexIntegration

struct CodexUsageParserTests {
    @Test("codex weekly data is read from the primary bucket")
    func weeklyInPrimaryBucket() throws {
        let result: [String: Any] = [
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": ["usedPercent": 41.0, "windowDurationMins": 10_080, "resetsAt": 1_800_000_000.0]
                ],
                "spark": ["primary": ["usedPercent": 1.0, "windowDurationMins": 300]]
            ]
        ]
        let snapshot = try CodexUsageParser.snapshot(from: result, sampledAt: Date(timeIntervalSince1970: 100))
        let weekly = try #require(snapshot.value(for: .weekly))
        #expect(weekly.usedPercent == 41)
        #expect(weekly.windowDurationMins == 10_080)
        #expect(snapshot.value(for: .fiveHour) == nil)
        #expect(snapshot.value(for: .automatic) == weekly)
    }

    @Test("automatic selection prefers the five-hour duration")
    func automaticPrefersFiveHour() throws {
        let result: [String: Any] = [
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": ["usedPercent": 29.5, "windowDurationMins": 10_080],
                    "secondary": ["usedPercent": 7.25, "windowDurationMins": 300]
                ]
            ]
        ]
        let snapshot = try CodexUsageParser.snapshot(from: result, sampledAt: Date())
        #expect(snapshot.value(for: .automatic)?.windowDurationMins == 300)
        #expect(snapshot.value(for: .automatic)?.usedPercent == 7.25)
    }

    @Test("missing, nonfinite, and unsupported values are omitted")
    func missingValues() throws {
        let result: [String: Any] = [
            "rateLimits": [
                "primary": [
                    "usedPercent": 50.0,
                    "windowDurationMins": 300,
                    "individualLimit": ["usedPercent": 99.0, "windowDurationMins": 10_080]
                ],
                "secondary": ["usedPercent": Double.nan, "windowDurationMins": 10_080],
                "other": ["usedPercent": 42.0, "windowDurationMins": 60],
                "booleanDuration": ["usedPercent": 5.0, "windowDurationMins": true],
                "fractionalDuration": ["usedPercent": 5.0, "windowDurationMins": 300.5],
                "hugeDuration": ["usedPercent": 5.0, "windowDurationMins": Double.greatestFiniteMagnitude]
            ]
        ]
        let snapshot = try CodexUsageParser.snapshot(from: result, sampledAt: Date())
        #expect(snapshot.value(for: .fiveHour)?.usedPercent == 50)
        #expect(snapshot.value(for: .weekly) == nil)
        #expect(snapshot.value(for: .automatic)?.usedPercent == 50)
    }

    @Test("percentages are clamped and legacy non-codex buckets are ignored")
    func normalizationAndBucketSelection() throws {
        let codex: [String: Any] = [
            "limitId": "codex",
            "primary": ["usedPercent": -10.0, "windowDurationMins": 300],
            "secondary": ["usedPercent": 125.0, "windowDurationMins": 10_080]
        ]
        let snapshot = try CodexUsageParser.snapshot(from: ["rateLimits": codex], sampledAt: Date())
        #expect(snapshot.value(for: .fiveHour)?.usedPercent == 0)
        #expect(snapshot.value(for: .weekly)?.usedPercent == 100)

        let spark = ["rateLimits": ["limitId": "spark", "primary": ["usedPercent": 10.0, "windowDurationMins": 300]]] as [String: Any]
        #expect(try CodexUsageParser.snapshot(from: spark, sampledAt: Date()).windows.isEmpty)
    }

    @Test("invalid durations are rejected without conversion traps")
    func invalidDurationBoundaries() throws {
        for duration: Any in [true, 300.5, Double(Int.max), Double.greatestFiniteMagnitude] {
            let result: [String: Any] = [
                "rateLimits": ["primary": ["usedPercent": 5.0, "windowDurationMins": duration]]
            ]
            #expect(try CodexUsageParser.snapshot(from: result, sampledAt: Date()).windows.isEmpty)
        }
    }
}
