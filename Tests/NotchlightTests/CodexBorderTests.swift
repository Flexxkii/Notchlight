import CodexIntegration
import Foundation
import AppKit
import SwiftUI
import Testing
@testable import Notchlight

@MainActor
struct CodexBorderTests {
    @Test("model grace timer expires and a later idle transition gets a fresh window")
    func modelGraceExpiryAndReactivation() async throws {
        let (model, defaults, suite) = makeVisibilityModel(timeout: 0.002)
        defer { defaults.removePersistentDomain(forName: suite) }
        model.codex.recordActivity(snapshot(working: true))
        model.showOnlyWhileWorking = true
        #expect(model.effectiveIsEnabled)
        model.codex.recordActivity(snapshot(working: false))
        #expect(model.effectiveIsEnabled)
        model.codex.recordActivity(snapshot(working: true))
        #expect(model.effectiveIsEnabled)
        try await Task.sleep(for: .milliseconds(180))
        #expect(model.effectiveIsEnabled)
        model.codex.recordActivity(snapshot(working: false))
        #expect(model.effectiveIsEnabled)
        try await waitForGraceExpiry()
        #expect(!model.effectiveIsEnabled)
    }

    @Test("unavailable activity retains grace across unrelated updates")
    func unavailableActivityRetainsGrace() async throws {
        // This case verifies preservation across updates, not scheduler latency.
        // A 120 ms grace could expire while other AppKit tests occupied the actor.
        let (model, defaults, suite) = makeVisibilityModel(timeout: 1)
        defer { defaults.removePersistentDomain(forName: suite) }
        model.codex.recordActivity(snapshot(working: true))
        model.showOnlyWhileWorking = true
        model.codex.recordActivity(snapshot(working: false))
        model.codex.recordActivity(snapshot(working: false, available: false))
        model.codex.recordUsage(CodexUsageSnapshot(windows: [], sampledAt: .now))
        model.lineWidth = 3
        #expect(model.effectiveIsEnabled)
        model.inactivityTimeoutMinutes = 0
        #expect(!model.effectiveIsEnabled)
    }

    @Test("timeout edits and unrelated updates use the original idle transition")
    func modelTimeoutEditsAndUnrelatedUpdates() async throws {
        let (model, defaults, suite) = makeVisibilityModel(timeout: 0.01)
        defer { defaults.removePersistentDomain(forName: suite) }
        model.codex.recordActivity(snapshot(working: true))
        model.showOnlyWhileWorking = true
        model.codex.recordActivity(snapshot(working: false))
        model.codex.recordUsage(CodexUsageSnapshot(windows: [], sampledAt: .now))
        model.lineWidth = 3
        await Task.yield()
        #expect(model.effectiveIsEnabled)

        model.inactivityTimeoutMinutes = 0.001
        try await Task.sleep(for: .milliseconds(180))
        #expect(!model.effectiveIsEnabled)

        model.codex.recordActivity(snapshot(working: true))
        model.inactivityTimeoutMinutes = 0.01
        model.codex.recordActivity(snapshot(working: false))
        try await Task.sleep(for: .milliseconds(100))
        model.inactivityTimeoutMinutes = 0.02
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.effectiveIsEnabled)
        try await Task.sleep(for: .milliseconds(1_300))
        #expect(!model.effectiveIsEnabled)
    }

    @Test("disconnect clears grace and stop does not rearm it")
    func modelDisconnectAndStop() async throws {
        let (model, defaults, suite) = makeVisibilityModel(timeout: 0.01)
        defer { defaults.removePersistentDomain(forName: suite) }
        model.codex.recordActivity(snapshot(working: true))
        model.showOnlyWhileWorking = true
        model.codex.recordActivity(snapshot(working: false))
        #expect(model.effectiveIsEnabled)
        model.codexLinked = false
        #expect(!model.effectiveIsEnabled)
        model.codexLinked = true
        model.codex.recordActivity(snapshot(working: false))
        #expect(!model.effectiveIsEnabled)

        model.codex.recordActivity(snapshot(working: true))
        model.codex.recordActivity(snapshot(working: false))
        model.stopServices()
        #expect(!model.effectiveIsEnabled)
        try await Task.sleep(for: .milliseconds(700))
        #expect(!model.effectiveIsEnabled)
    }

    @Test("activity visibility applies grace, expiry, disconnect, and master override")
    func activityVisibilityPolicy() {
        let idle = Date(timeIntervalSince1970: 1_000)
        #expect(ActivityVisibilityPolicy.isVisible(masterEnabled: true, filterEnabled: true, linked: true, available: true, working: true, idleSince: nil, now: Date(timeIntervalSince1970: 1_100), timeoutMinutes: 1))
        #expect(ActivityVisibilityPolicy.isVisible(masterEnabled: true, filterEnabled: true, linked: true, available: true, working: false, idleSince: idle, now: Date(timeIntervalSince1970: 1_059), timeoutMinutes: 1))
        #expect(!ActivityVisibilityPolicy.isVisible(masterEnabled: true, filterEnabled: true, linked: true, available: true, working: false, idleSince: idle, now: Date(timeIntervalSince1970: 1_060), timeoutMinutes: 1))
        #expect(ActivityVisibilityPolicy.isVisible(masterEnabled: true, filterEnabled: true, linked: true, available: false, working: false, idleSince: idle, now: Date(timeIntervalSince1970: 1_010), timeoutMinutes: 1))
        #expect(!ActivityVisibilityPolicy.isVisible(masterEnabled: true, filterEnabled: true, linked: true, available: false, working: false, idleSince: nil, now: Date(timeIntervalSince1970: 1_010), timeoutMinutes: 1))
        #expect(ActivityVisibilityPolicy.isVisible(masterEnabled: true, filterEnabled: false, linked: false, available: false, working: false, idleSince: nil, now: .now, timeoutMinutes: 0))
        #expect(!ActivityVisibilityPolicy.isVisible(masterEnabled: false, filterEnabled: false, linked: true, available: true, working: true, idleSince: nil, now: .now, timeoutMinutes: 1))
    }

    @Test("activity visibility preferences persist and normalize")
    func activityVisibilityPreferences() throws {
        let suite = "CodexBorderTests.visibility.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "border.enabled")
        let model = BorderModel(defaults: defaults, startIntegration: false, startOverlay: false)
        #expect(model.showOnlyWhileWorking == false)
        #expect(model.inactivityTimeoutMinutes == 1)
        model.showOnlyWhileWorking = true
        model.inactivityTimeoutMinutes = 90
        #expect(model.inactivityTimeoutMinutes == 60)
        let restored = BorderModel(defaults: defaults, startIntegration: false, startOverlay: false)
        #expect(restored.showOnlyWhileWorking)
        #expect(restored.inactivityTimeoutMinutes == 60)
        restored.inactivityTimeoutMinutes = .nan
        #expect(restored.inactivityTimeoutMinutes == 1)
    }

    @Test("working color follows active Codex state without replacing manual color")
    func workingColorSelection() throws {
        let suite = "CodexBorderTests.working-color.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "border.enabled")
        let model = BorderModel(defaults: defaults, startIntegration: false, startOverlay: false)
        model.borderColor = Color(.sRGB, red: 0.9, green: 0.1, blue: 0.2)
        model.workingColor = Color(.sRGB, red: 0.15, green: 0.55, blue: 1)

        expectColor(model.effectiveBorderColor, red: 0.9, green: 0.1, blue: 0.2)
        model.codex.recordActivity(CodexActivitySnapshot(isWorking: true, activeTaskCount: 1, isAvailable: true, detail: "Working", sampledAt: .now))
        expectColor(model.effectiveBorderColor, red: 0.15, green: 0.55, blue: 1)
        model.lineWidth = 3
        let busyRestored = BorderModel(defaults: defaults, startIntegration: false, startOverlay: false)
        expectColor(busyRestored.borderColor, red: 0.9, green: 0.1, blue: 0.2)
        model.codex.recordActivity(CodexActivitySnapshot(isWorking: false, activeTaskCount: 0, isAvailable: true, detail: "Idle", sampledAt: .now))
        expectColor(model.effectiveBorderColor, red: 0.9, green: 0.1, blue: 0.2)
        model.codex.recordActivity(CodexActivitySnapshot(isWorking: true, activeTaskCount: 1, isAvailable: false, detail: "Unavailable", sampledAt: .now))
        expectColor(model.effectiveBorderColor, red: 0.9, green: 0.1, blue: 0.2)
        model.codexLinked = false
        expectColor(model.effectiveBorderColor, red: 0.9, green: 0.1, blue: 0.2)
    }

    @Test("working color persists with documented default and reset")
    func workingColorPersistenceAndReset() throws {
        let suite = "CodexBorderTests.working-color-persistence.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "border.enabled")
        let model = BorderModel(defaults: defaults, startIntegration: false, startOverlay: false)
        expectColor(model.workingColor, red: 0.15, green: 0.55, blue: 1)
        model.workingColor = Color(.sRGB, red: 0.7, green: 0.2, blue: 0.4)
        let restored = BorderModel(defaults: defaults, startIntegration: false, startOverlay: false)
        expectColor(restored.workingColor, red: 0.7, green: 0.2, blue: 0.4)
        restored.resetAppearance()
        expectColor(restored.workingColor, red: 0.15, green: 0.55, blue: 1)
    }

    @Test("connected border displays used percentage without overwriting manual range")
    func usageDrivesEnd() throws {
        let suite = "CodexBorderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "border.enabled")
        let model = BorderModel(defaults: defaults, startIntegration: false, startOverlay: false)
        model.startPercentage = 15
        model.endPercentage = 85
        model.glow = true
        model.codex.recordUsage(CodexUsageSnapshot(
            windows: [CodexUsageValue(usedPercent: 41, windowDurationMins: 10_080, resetsAt: nil)],
            sampledAt: .now
        ))

        #expect(model.codexLinked)
        #expect(model.effectiveStartPercentage == 0)
        #expect(model.effectiveEndPercentage == 41)
        #expect(model.effectiveGlow == false)
        #expect(model.startPercentage == 15)
        #expect(model.endPercentage == 85)

        model.codexLinked = false
        #expect(model.effectiveStartPercentage == 15)
        #expect(model.effectiveEndPercentage == 85)
        #expect(model.effectiveGlow)

        let restored = BorderModel(defaults: defaults, startIntegration: false, startOverlay: false)
        #expect(restored.codexLinked == false)
        #expect(restored.startPercentage == 15)
        #expect(restored.endPercentage == 85)
        #expect(restored.glow == true)
    }

    @Test("Codex activity controls glow only while connected")
    func activityControlsGlow() throws {
        let suite = "CodexBorderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "border.enabled")
        let model = BorderModel(defaults: defaults, startIntegration: false, startOverlay: false)
        model.glow = true

        model.codex.recordActivity(CodexActivitySnapshot(
            isWorking: true, activeTaskCount: 1, isAvailable: true,
            detail: "Working", sampledAt: .now
        ))
        #expect(model.effectiveGlow == true)
        #expect(model.effectivePulse == true)

        model.codex.recordActivity(CodexActivitySnapshot(
            isWorking: false, activeTaskCount: 0, isAvailable: true,
            detail: "Idle", sampledAt: .now
        ))
        #expect(model.effectiveGlow == false)

        #expect(model.effectivePulse == false)

        model.codex.recordActivity(CodexActivitySnapshot(
            isWorking: true, activeTaskCount: 1, isAvailable: false,
            detail: "Unavailable", sampledAt: .now
        ))
        #expect(model.effectiveGlow == false)
        #expect(model.effectivePulse == false)

        model.codexLinked = false
        #expect(model.effectiveGlow == true)
        #expect(model.effectivePulse == false)
    }

    @Test("unavailable selected window is not represented as a measured zero")
    func missingWindow() throws {
        let suite = "CodexBorderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "border.enabled")
        let model = BorderModel(defaults: defaults, startIntegration: false, startOverlay: false)
        model.codex.recordUsage(CodexUsageSnapshot(
            windows: [CodexUsageValue(usedPercent: 41, windowDurationMins: 10_080, resetsAt: nil)],
            sampledAt: .now
        ))
        model.codexWindow = .fiveHour
        #expect(model.selectedUsage == nil)
        #expect(!model.hasVisibleLine)
        model.codexWindow = .automatic
        #expect(model.selectedUsage?.usedPercent == 41)
    }

    private func expectColor(_ color: Color, red: CGFloat, green: CGFloat, blue: CGFloat) {
        let nsColor = NSColor(color).usingColorSpace(.sRGB)!
        #expect(abs(nsColor.redComponent - red) < 0.001)
        #expect(abs(nsColor.greenComponent - green) < 0.001)
        #expect(abs(nsColor.blueComponent - blue) < 0.001)
    }

    private func makeVisibilityModel(timeout: Double) -> (BorderModel, UserDefaults, String) {
        let suite = "CodexBorderTests.timer.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "border.enabled")
        let model = BorderModel(defaults: defaults, startIntegration: false, startOverlay: false)
        model.inactivityTimeoutMinutes = timeout
        return (model, defaults, suite)
    }

    private func snapshot(working: Bool, available: Bool = true) -> CodexActivitySnapshot {
        CodexActivitySnapshot(isWorking: working, activeTaskCount: working ? 1 : 0,
                              isAvailable: available, detail: working ? "Working" : "Idle", sampledAt: .now)
    }

    private func waitForGraceExpiry() async throws {
        try await Task.sleep(for: .milliseconds(260))
    }
}
