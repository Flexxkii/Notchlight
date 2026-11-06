import AppKit
import Observation
import Sparkle

@MainActor @Observable
final class UpdateController {
    private(set) var canCheck = false
    private(set) var unavailableReason: String?
    var automaticallyChecks: Bool {
        didSet {
            if let updater = controller?.updater, updater.automaticallyChecksForUpdates != automaticallyChecks {
                updater.automaticallyChecksForUpdates = automaticallyChecks
            }
        }
    }
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var checkObservation: NSKeyValueObservation?
    @ObservationIgnored private var automaticObservation: NSKeyValueObservation?

    init(start: Bool = true) {
        automaticallyChecks = UserDefaults.standard.bool(forKey: "SUEnableAutomaticChecks")
        guard start else { unavailableReason = "Updates are available in the packaged app."; return }
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else {
            unavailableReason = "Run the packaged Notchlight app to check for updates."
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        checkObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let canCheck = change.newValue ?? false
            Task { @MainActor [weak self] in self?.canCheck = canCheck }
        }
        automaticObservation = controller.updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, change in
            let enabled = change.newValue ?? false
            Task { @MainActor [weak self] in self?.automaticallyChecks = enabled }
        }
        do { try controller.updater.start() }
        catch { unavailableReason = error.localizedDescription }
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
    }

    func checkForUpdates() {
        guard canCheck else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }
}
