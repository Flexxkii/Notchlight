import AppKit
import Diagnostics
import Foundation
import Testing
@testable import Notchlight
import CodexIntegration

@MainActor
struct DiagnosticsIntegrationTests {
    @Test("diagnostic preference persists independently of appearance settings")
    func recordingPreference() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let controller = DiagnosticsController(defaults: fixture.defaults, recorder: fixture.recorder, observeSystem: false)
        #expect(controller.recordingEnabled)
        controller.recordingEnabled = false
        #expect(!fixture.recorder.isEnabled)
        #expect(fixture.defaults.object(forKey: "diagnostics.enabled") as? Bool == false)
        controller.recordingEnabled = true
        #expect(fixture.recorder.isEnabled)
        #expect(fixture.defaults.object(forKey: "diagnostics.enabled") as? Bool == true)
    }

    @Test("automatic context distinguishes connection, working glow, and appearance")
    func automaticModelContext() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(false, forKey: "codex.linked")
        let model = BorderModel(defaults: fixture.defaults, startIntegration: false, startOverlay: false,
                                diagnostics: fixture.recorder)
        defer { model.stopServices() }
        model.codexLinked = true
        model.codex.recordActivity(CodexActivitySnapshot(isWorking: true, activeTaskCount: 3,
            isAvailable: true, detail: "PRIVATE_SENTINEL_DO_NOT_LOG", sampledAt: .now))
        model.showOnlyWhileWorking = true
        model.isEnabled = false
        fixture.recorder.flush()
        let logs = try fixture.logs()
        #expect(logs.contains("codex_connected"))
        #expect(logs.contains("codex_working"))
        #expect(logs.contains("active_task_count"))
        #expect(logs.contains("pulse_requested"))
        #expect(logs.contains("border_effective_enabled"))
        #expect(!logs.contains("PRIVATE_SENTINEL_DO_NOT_LOG"))
        let contexts = try fixture.contexts()
        #expect(contexts.contains { $0["codex_connected"] as? Bool == false })
        #expect(contexts.contains { $0["codex_connected"] as? Bool == true })
        #expect(contexts.contains { $0["codex_working"] as? Bool == true })
        #expect(contexts.contains { $0["active_task_count"] as? Int == 3 })
        #expect(contexts.contains { $0["border_effective_enabled"] as? Bool == false })
    }

    @Test("settings diagnostics observe the actual window without starting a SwiftUI timer")
    func windowVisibility() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = SettingsWindowObserverView(recorder: fixture.recorder)
        window.contentView = view
        window.orderFront(nil)
        view.recordState()
        window.orderOut(nil)
        view.recordState()
        window.close()
        fixture.recorder.flush()
        let logs = try fixture.logs()
        #expect(logs.contains("settings_visible"))
        #expect(logs.contains("settings_minimized"))
        #expect(logs.contains("settings_occluded"))
        let contexts = try fixture.contexts()
        #expect(contexts.contains { $0["settings_visible"] as? Bool == true })
        #expect(contexts.contains { $0["settings_visible"] as? Bool == false })
    }

    @Test("app export finishes while recording stays enabled")
    func controllerExport() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let controller = DiagnosticsController(defaults: fixture.defaults, recorder: fixture.recorder, observeSystem: false)
        let zip = fixture.directory.appendingPathComponent("export.zip")
        controller.export(to: zip, reveal: false)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while controller.isExporting, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!controller.isExporting)
        #expect(controller.exportError == nil)
        #expect(controller.lastExportURL == zip)
        #expect(fixture.recorder.isEnabled)
        #expect(FileManager.default.fileExists(atPath: zip.path))
    }

    private func makeFixture() throws -> Fixture {
        let suite = "NotchlightDiagnosticsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let recorder = DiagnosticRecorder(directory: directory.appendingPathComponent("logs"))
        return Fixture(defaults: defaults, suite: suite, directory: directory, recorder: recorder)
    }

    private struct Fixture {
        let defaults: UserDefaults
        let suite: String
        let directory: URL
        let recorder: DiagnosticRecorder

        func cleanup() {
            recorder.shutdown()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        func logs() throws -> String {
            let files = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("logs"),
                includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }
            return try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        }

        func contexts() throws -> [[String: Any]] {
            try logs().split(separator: "\n").compactMap { line in
                guard let event = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      event["event"] as? String == "context" else { return nil }
                return event["fields"] as? [String: Any]
            }
        }
    }
}
