import Observation
import ServiceManagement

/// macOS owns this preference; never mirror it in UserDefaults or register on launch.
@MainActor
@Observable
final class LoginItemController {
    private(set) var status: SMAppService.Status
    private(set) var errorMessage: String?

    @ObservationIgnored private let readStatus: () -> SMAppService.Status
    @ObservationIgnored private let register: () throws -> Void
    @ObservationIgnored private let unregister: () throws -> Void
    @ObservationIgnored private let openLoginItems: () -> Void

    init(
        readStatus: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
        register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
        unregister: @escaping () throws -> Void = { try SMAppService.mainApp.unregister() },
        openLoginItems: @escaping () -> Void = { SMAppService.openSystemSettingsLoginItems() }
    ) {
        self.readStatus = readStatus
        self.register = register
        self.unregister = unregister
        self.openLoginItems = openLoginItems
        status = readStatus()
    }

    var isEnabled: Bool {
        get { status == .enabled }
        set { setEnabled(newValue) }
    }

    var requiresApproval: Bool { status == .requiresApproval }

    func refreshStatus() {
        let current = readStatus()
        if current != status {
            errorMessage = nil
        }
        status = current
    }

    func openSystemSettings() {
        openLoginItems()
    }

    private func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        refreshStatus()

        do {
            if enabled {
                switch status {
                case .enabled:
                    return
                case .requiresApproval:
                    // A user or administrator disabled the existing registration.
                    // Respect that decision; only System Settings can approve it again.
                    openSystemSettings()
                    return
                default:
                    try register()
                }
            } else if status == .enabled || status == .requiresApproval {
                try unregister()
            }
        } catch {
            // A failed operation must not leave the checkbox in an optimistic state.
            status = readStatus()
            errorMessage = "Couldn’t \(enabled ? "enable" : "disable") launch at login. \(error.localizedDescription)"
            return
        }

        refreshStatus()
    }
}
