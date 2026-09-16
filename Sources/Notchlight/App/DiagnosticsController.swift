import AppKit
import Diagnostics
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class DiagnosticsController {
    @ObservationIgnored let recorder: DiagnosticRecorder
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    private(set) var enabled: Bool
    private(set) var errorCategory: String?
    private(set) var isExporting = false
    private(set) var lastExportURL: URL?
    var exportError: String?

    var recordingEnabled: Bool {
        get { enabled }
        set { setEnabled(newValue) }
    }

    var statusText: String {
        if errorCategory != nil { return "Recording unavailable — check the logs folder." }
        return enabled ? "Recording locally · up to 24 hours / 50 MiB" : "Recording is off · saved logs remain available"
    }

    init(defaults: UserDefaults = .standard, recorder: DiagnosticRecorder? = nil, observeSystem: Bool = true) {
        self.defaults = defaults
        defaults.register(defaults: ["diagnostics.enabled": true])
        let activeRecorder = recorder ?? DiagnosticRecorder(enabled: defaults.bool(forKey: "diagnostics.enabled"))
        self.recorder = activeRecorder
        enabled = activeRecorder.status.isEnabled
        errorCategory = activeRecorder.status.errorCategory
        activeRecorder.updateContext([
            "system_sleeping": .bool(false),
            "settings_visible": .bool(false),
            "settings_minimized": .bool(false),
            "settings_occluded": .bool(true),
            "preview_present": .bool(false),
            "preview_pulse_active": .bool(false),
            "diagnostics_exporting": .bool(false)
        ])
        activeRecorder.onStatusChange = { [weak self] status in
            Task { @MainActor [weak self] in
                self?.enabled = status.isEnabled
                self?.errorCategory = status.errorCategory
            }
        }
        if observeSystem { installSystemObservers() }
    }

    isolated deinit {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: "diagnostics.enabled")
        recorder.setEnabled(enabled)
        self.enabled = recorder.status.isEnabled
        errorCategory = recorder.status.errorCategory
    }

    func revealLogs() {
        if !NSWorkspace.shared.open(recorder.status.directory) {
            exportError = "The logs folder is not available yet. Enable diagnostic logging to create it."
        }
    }

    func chooseExportDestination() {
        guard !isExporting else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Notchlight-diagnostics-\(Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))).zip"
        panel.message = "Save local performance logs and a summary report. No conversation content is included."
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.export(to: url)
        }
    }

    func export(to url: URL, reveal: Bool = true) {
        guard !isExporting else { return }
        isExporting = true
        exportError = nil
        recorder.updateContext(["diagnostics_exporting": .bool(true)])
        let recorder = recorder
        Task {
            do {
                try await Task.detached(priority: .utility) { try recorder.export(to: url) }.value
                lastExportURL = url
                if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } catch {
                exportError = "Diagnostics could not be exported. Check the destination and available disk space, then try again."
            }
            recorder.updateContext(["diagnostics_exporting": .bool(false)])
            isExporting = false
        }
    }

    func shutdown() {
        recorder.shutdown()
    }

    private func installSystemObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for (notification, sleeping, reason) in [
            (NSWorkspace.willSleepNotification, true, "sleep"),
            (NSWorkspace.didWakeNotification, false, "wake")
        ] {
            observers.append(center.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.recorder.updateContext(["system_sleeping": .bool(sleeping)])
                    self.recorder.resetBaseline(reason: reason)
                }
            })
        }
    }
}
