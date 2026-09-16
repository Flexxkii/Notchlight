import AppKit

@MainActor
final class NotchMenuController: NSObject {
    weak var model: BorderModel?

    init(model: BorderModel) {
        self.model = model
        super.init()
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let status = NSMenuItem(title: model?.statusLabel ?? "Border unavailable", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let connect = NSMenuItem(title: "Connect to Codex", action: #selector(toggleCodex(_:)), keyEquivalent: "")
        connect.target = self
        connect.state = model?.codexLinked == true ? .on : .off
        menu.addItem(connect)

        let showBorder = NSMenuItem(title: "Show border", action: #selector(toggleBorder(_:)), keyEquivalent: "b")
        showBorder.keyEquivalentModifierMask = [.command, .shift]
        showBorder.target = self
        showBorder.state = model?.isEnabled == true ? .on : .off
        menu.addItem(showBorder)
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self
        menu.addItem(settings)

        let export = NSMenuItem(title: "Export diagnostics…", action: #selector(exportDiagnostics(_:)), keyEquivalent: "")
        export.target = self
        menu.addItem(export)

        let quit = NSMenuItem(title: "Quit Notchlight", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func toggleCodex(_ sender: NSMenuItem) {
        model?.codexLinked.toggle()
    }

    @objc private func toggleBorder(_ sender: NSMenuItem) {
        model?.isEnabled.toggle()
    }

    @objc private func showSettings(_ sender: NSMenuItem) {
        model?.showSettings()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        model?.quit()
    }

    @objc private func exportDiagnostics(_ sender: NSMenuItem) {
        model?.exportDiagnostics()
    }
}
