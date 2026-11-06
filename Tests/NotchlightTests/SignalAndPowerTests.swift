import Foundation
import Testing
import StatusSignals
import CodexIntegration
@testable import Notchlight

@MainActor struct SignalAndPowerTests {
    @Test func signalsRespectOptInConnectionAndMasterVisibility() throws {
        let suite = "signals-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = BorderModel(defaults: defaults, startIntegration: false, startOverlay: false)
        defer { model.stopServices() }
        model.isEnabled = true
        model.showOnlyWhileWorking = true
        let signal = try StatusSignal(source: "build", state: .working, message: "Building")
        model.signals.record([signal])
        #expect(model.activeSignal == nil)
        model.customSignalsEnabled = true
        #expect(model.activeSignal == signal)
        #expect(model.effectiveIsEnabled)
        #expect(model.effectiveEndPercentage == 100)
        #expect(model.hoverContent.resetText == "Building")
        #expect(model.effectivePulse)
        model.isEnabled = false
        #expect(!model.effectiveIsEnabled)
        model.isEnabled = true
        let attention = try StatusSignal(source: "codex-fixture", state: .attention, message: "Codex requested approval",
                                         codexSession: "session", codexTurn: "turn")
        model.signals.record([attention, signal])
        #expect(model.activeSignal == attention)
        #expect(!model.effectivePulse)
        model.codexLinked = false
        #expect(model.activeSignal == signal)
        model.customSignalsEnabled = false
        #expect(model.activeSignal == nil)
        #expect(!model.effectiveIsEnabled)
    }

    @Test func powerTransitionsPreserveAppearanceAndStatus() {
        let suite = "power-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = BorderModel(defaults: defaults, startIntegration: false, startOverlay: false)
        defer { model.stopServices() }
        model.codex.recordActivity(CodexActivitySnapshot(isWorking: true, activeTaskCount: 1,
                                                        isAvailable: true, detail: "Working", sampledAt: .now))
        model.glow = true
        model.power.record(onBattery: true, lowPowerMode: false)
        #expect(model.effectivePulse) // Opt-in, never silently changes saved appearance.
        model.batteryAwareEffects = true
        #expect(model.effectsReduced)
        #expect(!model.effectiveGlow && !model.effectivePulse)
        #expect(model.codex.isWorking)
        model.power.record(onBattery: false, lowPowerMode: true)
        #expect(model.effectsReduced)
        model.power.record(onBattery: false, lowPowerMode: false)
        #expect(model.effectiveGlow && model.effectivePulse)
        model.codexLinked = false
        model.power.record(onBattery: true, lowPowerMode: false)
        #expect(!model.effectiveGlow)
        #expect(model.glow)
        model.batteryAwareEffects = false
        #expect(model.effectiveGlow)
        let restored = BorderModel(defaults: defaults, startIntegration: false, startOverlay: false)
        #expect(!restored.batteryAwareEffects)
        #expect(restored.glow)
    }

    @Test func monitorWatchesAtomicWritesAndExpiresWithoutPolling() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("signal-watch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SignalStore(directory: directory)
        let monitor = SignalMonitor(store: store)
        monitor.start()
        defer { monitor.stop() }
        try store.write(StatusSignal(source: "test", state: .success, message: "Finished", lifetime: 1))
        for _ in 0..<40 where monitor.signals.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        #expect(monitor.signals.count == 1)
        try await Task.sleep(for: .milliseconds(1_100))
        #expect(monitor.signals.isEmpty)
    }
}
