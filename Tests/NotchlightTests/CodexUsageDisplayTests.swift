import CodexIntegration
import Foundation
import Testing
@testable import Notchlight

@MainActor
struct CodexUsageDisplayTests {
    @Test("usage display defaults to used and persists remaining across model recreation")
    func persistence() throws {
        let suite = "CodexUsageDisplayTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = BorderModel(defaults: defaults, startIntegration: false, startOverlay: false)
        #expect(model.codexUsageDisplay == .used)
        model.codexUsageDisplay = .remaining
        let restored = BorderModel(defaults: defaults, startIntegration: false, startOverlay: false)
        #expect(restored.codexUsageDisplay == .remaining)
        // Reset appearance should preserve this account-display preference,
        // just as it preserves the selected usage window.
        restored.resetAppearance()
        #expect(restored.codexUsageDisplay == .remaining)
        restored.codexUsageDisplay = .used
        #expect(defaults.string(forKey: "codex.usageDisplay") == "used")
    }

    @Test("unknown saved display values fall back to used")
    func invalidPreference() throws {
        let suite = "CodexUsageDisplayTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unknown", forKey: "codex.usageDisplay")
        let model = BorderModel(defaults: defaults, startIntegration: false, startOverlay: false)
        #expect(model.codexUsageDisplay == .used)
    }

    @Test("remaining display follows the selected window without changing raw usage or manual range")
    func selectedWindowAndManualRange() throws {
        let suite = "CodexUsageDisplayTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = BorderModel(defaults: defaults, startIntegration: false, startOverlay: false)
        model.startPercentage = 15
        model.endPercentage = 85
        model.codex.recordUsage(CodexUsageSnapshot(windows: [
            CodexUsageValue(usedPercent: 41, windowDurationMins: 300, resetsAt: nil),
            CodexUsageValue(usedPercent: 72.5, windowDurationMins: 10_080, resetsAt: nil)
        ], sampledAt: .now))
        #expect(model.effectiveEndPercentage == 41)
        model.codexUsageDisplay = .remaining
        #expect(model.selectedUsage?.usedPercent == 41)
        #expect(model.selectedUsagePercentage == 59)
        #expect(model.effectiveStartPercentage == 0)
        #expect(model.effectiveEndPercentage == 59)
        model.codexWindow = .weekly
        #expect(model.selectedUsagePercentage == 27.5)
        #expect(model.effectiveEndPercentage == 27.5)
        model.codexUsageDisplay = .used
        #expect(model.effectiveEndPercentage == 72.5)
        model.codexUsageDisplay = .remaining
        model.codexLinked = false
        #expect(model.effectiveStartPercentage == 15)
        #expect(model.effectiveEndPercentage == 85)
    }

    @Test("missing usage never becomes a full remaining allowance")
    func missingUsage() throws {
        let suite = "CodexUsageDisplayTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = BorderModel(defaults: defaults, startIntegration: false, startOverlay: false)
        model.codexUsageDisplay = .remaining
        #expect(model.selectedUsagePercentage == nil)
        #expect(model.effectiveEndPercentage == 0)
        model.codex.recordUsage(CodexUsageSnapshot(windows: [
            CodexUsageValue(usedPercent: 41, windowDurationMins: 10_080, resetsAt: nil)
        ], sampledAt: .now))
        model.codexWindow = .fiveHour
        #expect(model.selectedUsagePercentage == nil)
        #expect(model.effectiveEndPercentage == 0)
        model.codexWindow = .automatic
        #expect(model.effectiveEndPercentage == 59)
    }

    @Test("remaining conversion handles empty, full, and fractional usage", arguments: [0.0, 100.0, 12.5])
    func percentageBoundaries(used: Double) {
        let usage = CodexUsageValue(usedPercent: used, windowDurationMins: 300, resetsAt: nil)
        #expect(CodexUsageDisplay.used.percentage(for: usage) == used)
        #expect(CodexUsageDisplay.remaining.percentage(for: usage) == 100 - used)
    }
}
