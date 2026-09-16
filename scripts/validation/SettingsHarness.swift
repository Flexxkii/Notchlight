// Standalone release fixture. Does not read Codex or the user's saved preferences.
import AppKit
import SwiftUI
import CodexIntegration
import Diagnostics
import Observation

@MainActor @Observable
final class ValidationState {
    var dark = true
}

struct ValidationRoot: View {
    let model: BorderModel
    let state: ValidationState
    var body: some View {
        SettingsView(model: model)
            .environment(\.colorScheme, state.dark ? .dark : .light)
    }
}

@MainActor
final class Harness: NSObject, NSApplicationDelegate {
    let state = ValidationState()
    let suite = "com.notchlight.optimization-validation.\(UUID().uuidString)"
    let model: BorderModel
    let defaults: UserDefaults
    let window: NSWindow

    override init() {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "codex.linked")
        defaults.set(false, forKey: "border.hideWhenSwiping")
        model = BorderModel(defaults: defaults, startIntegration: false, startOverlay: false)
        window = NSWindow(contentRect: NSRect(x: 160, y: 120, width: 500, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        model.codex.recordUsage(CodexUsageSnapshot(windows: [CodexUsageValue(usedPercent: 48, windowDurationMins: 300, resetsAt: Date().addingTimeInterval(2 * 60 * 60 + 15 * 60))], sampledAt: Date()))
        setWorking(true)
        window.title = "Notchlight — Sample data"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ValidationRoot(model: model, state: state))
        window.appearance = NSAppearance(named: .darkAqua)
        model.openSettingsAction = { [weak self] in self?.window.makeKeyAndOrderFront(nil) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let menu = NSMenu(title: "Validation"); appItem.submenu = menu
        for (title, action, key) in [
            ("Toggle light / dark", #selector(toggleAppearance), "l"),
            ("Minimum size (500 × 480)", #selector(minimumSize), "1"),
            ("Default size (500 × 820)", #selector(defaultSize), "2"),
            ("Deactivate window", #selector(deactivate), "3"),
            ("Toggle busy / idle", #selector(toggleWorking), "b"),
            ("Settings…", #selector(showSettings), ","),
            ("Legal documents…", #selector(showLegal), "j"),
            ("Quit", #selector(quit), "q")
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self; menu.addItem(item)
        }
        NSApp.mainMenu = main
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--measure") {
            Task { await measure() }
        }
    }
    func setWorking(_ working: Bool) {
        model.codex.recordActivity(CodexActivitySnapshot(isWorking: working, activeTaskCount: working ? 1 : 0, isAvailable: true, detail: working ? "Codex working" : "Codex idle", sampledAt: Date()))
    }
    @objc func toggleAppearance() { state.dark.toggle(); window.appearance = NSAppearance(named: state.dark ? .darkAqua : .aqua) }
    @objc func minimumSize() { window.setContentSize(NSSize(width: 500, height: 480)) }
    @objc func defaultSize() { window.setContentSize(NSSize(width: 500, height: 820)) }
    @objc func deactivate() {
        NSApp.deactivate()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard let view = window.contentView else { return }
            let directory = Bundle.main.bundleURL.deletingLastPathComponent()
            let values: [String: Any] = ["appActive": NSApp.isActive, "windowKey": window.isKeyWindow,
                                       "windowVisible": window.isVisible, "width": view.bounds.width,
                                       "height": view.bounds.height]
            try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]).write(to: directory.appendingPathComponent("inactive-state.json"))
        }
    }
    @objc func toggleWorking() { setWorking(!model.codex.isWorking) }
    @objc func showSettings() { window.makeKeyAndOrderFront(nil) }
    private var legalWindow: NSWindow?
    @objc func showLegal() {
        if let legalWindow { legalWindow.makeKeyAndOrderFront(nil); return }
        let legal = NSWindow(contentRect: NSRect(x: 210, y: 150, width: 680, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        legal.title = "About Notchlight & Legal"
        legal.isReleasedWhenClosed = false
        legal.appearance = NSAppearance(named: state.dark ? .darkAqua : .aqua)
        legal.contentView = NSHostingView(rootView: LegalDocumentsView())
        legalWindow = legal
        legal.makeKeyAndOrderFront(nil)
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { model.stopServices(); defaults.removePersistentDomain(forName: suite) }

    func measure() async {
        for phase in ["busy-visible", "busy-minimized", "busy-closed", "busy-reopened", "busy-ordered-out", "idle-visible"] {
            switch phase {
            case "busy-minimized": window.miniaturize(nil)
            case "busy-closed": window.close()
            case "busy-reopened": window.deminiaturize(nil); window.makeKeyAndOrderFront(nil)
            case "busy-ordered-out": window.orderOut(nil)
            case "idle-visible": setWorking(false); window.makeKeyAndOrderFront(nil)
            default: break
            }
            try? await Task.sleep(for: .seconds(2))
            let before = try! ProcessResourceSnapshot.read()
            let start = DispatchTime.now().uptimeNanoseconds
            try? await Task.sleep(for: .seconds(10))
            let after = try! ProcessResourceSnapshot.read()
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            let cpu = Double(after.userTimeNanoseconds + after.systemTimeNanoseconds - before.userTimeNanoseconds - before.systemTimeNanoseconds) / 1e9
            let result: [String: Any] = ["phase": phase, "seconds": elapsed, "cpuPercent": cpu / elapsed * 100, "footprintMiB": Double(after.physicalFootprintBytes) / 1048576, "wakeups": after.interruptWakeups - before.interruptWakeups, "windowVisible": window.isVisible, "windowOccluded": !window.occlusionState.contains(.visible), "minimized": window.isMiniaturized]
            let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            FileHandle.standardOutput.write(data + Data([10]))
        }
        NSApp.terminate(nil)
    }
}

@main struct SettingsHarness {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let harness = Harness()
        app.delegate = harness
        withExtendedLifetime(harness) { app.run() }
    }
}
