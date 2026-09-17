// Compile with BorderOverlay sources and the built Diagnostics module/objects.
// Uses a simulated notch and never reads or writes the user's preferences.
import AppKit
import SwiftUI

@MainActor
final class NotchMenuHintHarness: NSObject, NSApplicationDelegate {
    let window = NSWindow(contentRect: CGRect(x: 300, y: 400, width: 520, height: 300),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let controller = NotchMenuHintController(duration: CommandLine.arguments.contains("--verify") ? .seconds(1) : .seconds(45))
    var completions = 0
    var embeddedHint: NSView?
    private var presentationTask: Task<Void, Never>?
    private var isVerifying: Bool { CommandLine.arguments.contains("--verify") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.title = "Notchlight — First-run hint fixture"
        window.isReleasedWhenClosed = false
        window.center()
        if CommandLine.arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if CommandLine.arguments.contains("--contrast") { NSApp.appearance = NSAppearance(named: .accessibilityHighContrastAqua) }
        window.appearance = NSApp.appearance
        let content = NSVisualEffectView(frame: CGRect(origin: .zero, size: window.contentLayoutRect.size))
        content.material = .windowBackground
        content.state = .active
        let camera = NSView(frame: CGRect(x: 170, y: content.bounds.maxY - 32, width: 180, height: 32))
        camera.wantsLayer = true
        camera.layer?.backgroundColor = NSColor.black.cgColor
        camera.layer?.cornerRadius = 8
        content.addSubview(camera)
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard let screen = window.screen ?? NSScreen.main else {
            reportFailure("No display is available for the preview")
            return
        }
        let target = NotchMenuHintController.Target(notch: window.convertToScreen(camera.frame), screen: screen.frame)
        controller.offer { [weak self] in self?.completions += 1 }
        controller.reconcile(target: target)
        presentationTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(1.8)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            // Regression scenario: losing focus is normal during a preview.
            if CommandLine.arguments.contains("--without-focus") {
                window.resignKey()
                print("FOCUS: fixture window is key=\(window.isKeyWindow)")
            }
            guard let panel = controller.panel else {
                // An interactive user may already have dismissed the hint.
                if isVerifying { reportFailure("Hint did not present") }
                return
            }
            if isVerifying {
                guard completions == 1, panel.isVisible,
                      !panel.isKeyWindow, !panel.canBecomeKey, !panel.canBecomeMain,
                      panel.frame.maxY < target.notch.minY else {
                    reportFailure("Expected one visible, nonactivating hint below the notch")
                    return
                }
                print("PASS: presented once below notch without taking focus; size=\(panel.frame.size)")
            }
            print("CAPTURE: window=\(window.windowNumber) panel=\(panel.windowNumber)")
            fflush(stdout)
            // CUA captures the main window without floating panels. Embed the
            // identical production view for visual and accessibility inspection.
            if CommandLine.arguments.contains("--embedded") {
                panel.orderOut(nil)
                let preview = NSHostingView(rootView: NotchMenuHintView { [weak self] in
                    self?.controller.dismiss()
                    self?.embeddedHint?.removeFromSuperview()
                    self?.embeddedHint = nil
                    print("PASS: dismiss button removed the hint")
                    fflush(stdout)
                })
                preview.frame = window.convertFromScreen(panel.frame)
                content.addSubview(preview)
                embeddedHint = preview
            }
            if isVerifying {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard controller.panel == nil else {
                    reportFailure("Hint did not disappear after its timeout")
                    return
                }
                controller.reconcile(target: target)
                do { try await Task.sleep(for: .seconds(1.7)) } catch { return }
                guard controller.panel == nil, completions == 1 else {
                    reportFailure("Hint replayed after completing discovery")
                    return
                }
                print("PASS: timeout removes panel and repeated updates do not replay")
                fflush(stdout)
                NSApp.terminate(nil)
            }
        }
    }

    private func reportFailure(_ message: String) {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        controller.stop()
        if isVerifying {
            // A validation failure is a failed command, not a macOS crash.
            exit(EXIT_FAILURE)
        }
        NSApp.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        presentationTask?.cancel()
        controller.stop()
    }
}

@main
struct HintValidationMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = NotchMenuHintHarness()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
    }
}
