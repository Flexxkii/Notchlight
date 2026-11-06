import AppKit
import SwiftUI

// Isolated updater UI using the production controller and view. The fixture's
// bundle ID and defaults domain differ from the installed Notchlight app.
@main struct UpdateHarness: App {
    @State private var updater = UpdateController()

    init() {
        let previous = UserDefaults.standard.string(forKey: "validation.setting")
        if previous == nil { UserDefaults.standard.set("preserve-this-setting", forKey: "validation.setting") }
        let evidence: [String: String] = [
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "missing",
            "previousSetting": previous ?? "absent",
            "setting": UserDefaults.standard.string(forKey: "validation.setting") ?? "missing"
        ]
        let destination = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("relaunch.json")
        try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: destination, options: .atomic)
    }

    var body: some Scene {
        WindowGroup("Notchlight Update Test") {
            UpdateSettingsView(controller: updater).padding(24).frame(width: 520)
        }
    }
}
