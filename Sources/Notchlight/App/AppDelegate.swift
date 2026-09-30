import AppKit
import WidgetShared

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() -> Void)?
    var onReopen: (() -> Void)?
    private var pendingUsageOpen = false
    var onOpenUsage: (() -> Void)? {
        didSet {
            if pendingUsageOpen, let onOpenUsage {
                pendingUsageOpen = false
                onOpenUsage()
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        handleUsageURLs(urls)
    }

    func handleUsageURLs(_ urls: [URL]) {
        guard urls.contains(WidgetSnapshot.settingsURL) else { return }
        if let onOpenUsage { onOpenUsage() } else { pendingUsageOpen = true }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        onReopen?()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        onTerminate?()
    }
}
