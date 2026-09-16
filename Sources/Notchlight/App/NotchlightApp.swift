import SwiftUI

@main
struct NotchlightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: BorderModel
    @State private var diagnostics: DiagnosticsController
    @Environment(\.openWindow) private var openWindow

    init() {
        let diagnostics = DiagnosticsController()
        _diagnostics = State(initialValue: diagnostics)
        _model = State(initialValue: BorderModel(diagnostics: diagnostics.recorder))
    }

    var body: some Scene {
        Window("Notchlight", id: "settings") {
            SettingsView(model: model, diagnostics: diagnostics)
                .onAppear {
                    model.openSettingsAction = {
                        openWindow(id: "settings")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    model.exportDiagnosticsAction = diagnostics.chooseExportDestination
                    appDelegate.onTerminate = {
                        model.stopServices()
                        diagnostics.shutdown()
                    }
                    appDelegate.onReopen = model.showSettings
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 500, height: 820)
        .defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Notchlight & Legal…") {
                    openWindow(id: "legal")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…", action: model.showSettings)
                    .keyboardShortcut(",")
            }
            CommandMenu("Border") {
                Toggle("Show border", isOn: $model.isEnabled)
                    .keyboardShortcut("b", modifiers: [.command, .shift])
            }
        }

        Window("About Notchlight & Legal", id: "legal") {
            LegalDocumentsView()
        }
        .defaultSize(width: 680, height: 640)
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)
    }
}
