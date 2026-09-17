import Foundation
import ServiceManagement
import Testing
@testable import Notchlight

@MainActor
struct LoginItemControllerTests {
    @Test func openingSettingsOnlyReadsTheSystemPreference() {
        let service = LoginItemStub(status: .enabled)
        let controller = service.makeController()
        #expect(controller.isEnabled)
        #expect(service.operations.isEmpty)
    }

    @Test func enablingAndDisablingUsesSystemRegistration() {
        let service = LoginItemStub()
        let controller = service.makeController()
        #expect(!controller.isEnabled)

        controller.isEnabled = true
        #expect(controller.isEnabled)
        #expect(service.status == .enabled)
        controller.isEnabled = false
        #expect(!controller.isEnabled)
        #expect(service.status == .notRegistered)
        #expect(service.operations == ["register", "unregister"])
    }

    @Test func repeatedRequestsDoNotRepeatRegistration() {
        let service = LoginItemStub()
        let controller = service.makeController()
        controller.isEnabled = false
        controller.isEnabled = true
        controller.isEnabled = true
        controller.isEnabled = false
        controller.isEnabled = false
        #expect(service.operations == ["register", "unregister"])
    }

    @Test func systemSettingsChangesRefreshWithoutChangingRegistration() {
        let service = LoginItemStub(status: .enabled)
        let controller = service.makeController()
        service.status = .requiresApproval
        controller.refreshStatus()
        #expect(!controller.isEnabled)
        #expect(controller.requiresApproval)

        service.status = .enabled
        controller.refreshStatus()
        #expect(controller.isEnabled)
        #expect(!controller.requiresApproval)
        #expect(service.operations.isEmpty)
    }

    @Test func pendingApprovalIsNotReportedAsEnabled() {
        let service = LoginItemStub()
        service.registrationStatus = .requiresApproval
        let controller = service.makeController()
        controller.isEnabled = true
        #expect(!controller.isEnabled)
        #expect(controller.requiresApproval)
        #expect(controller.errorMessage == nil)

        controller.isEnabled = true
        #expect(service.operations == ["register", "openSettings"])
        controller.isEnabled = false
        #expect(service.status == .notRegistered)
    }

    @Test func enableRechecksAStaleSystemStatus() {
        let service = LoginItemStub()
        let controller = service.makeController()
        service.status = .enabled
        controller.isEnabled = true
        #expect(controller.isEnabled)
        #expect(service.operations.isEmpty)
    }

    @Test func registrationFailureKeepsTheCheckboxOffAndCanBeRetried() {
        let service = LoginItemStub()
        service.fails = true
        let controller = service.makeController()
        controller.isEnabled = true
        #expect(!controller.isEnabled)
        #expect(controller.errorMessage?.contains("Couldn’t enable") == true)

        service.fails = false
        controller.isEnabled = true
        #expect(controller.isEnabled)
        #expect(controller.errorMessage == nil)
    }

    @Test func unregisterFailureKeepsTheCheckboxOn() {
        let service = LoginItemStub(status: .enabled)
        service.fails = true
        let controller = service.makeController()
        controller.isEnabled = false
        #expect(controller.isEnabled)
        #expect(controller.errorMessage?.contains("Couldn’t disable") == true)
    }

    @Test func aMissingServiceCanBeRegistered() {
        let service = LoginItemStub(status: .notFound)
        let controller = service.makeController()
        #expect(!controller.isEnabled)
        controller.isEnabled = true
        #expect(controller.isEnabled)
        #expect(service.operations == ["register"])
    }
}

@MainActor
private final class LoginItemStub {
    var status: SMAppService.Status
    var registrationStatus: SMAppService.Status = .enabled
    var fails = false
    var operations: [String] = []

    init(status: SMAppService.Status = .notRegistered) {
        self.status = status
    }

    func makeController() -> LoginItemController {
        LoginItemController(
            readStatus: { self.status },
            register: {
                self.operations.append("register")
                try self.checkFailure()
                self.status = self.registrationStatus
            },
            unregister: {
                self.operations.append("unregister")
                try self.checkFailure()
                self.status = .notRegistered
            },
            openLoginItems: { self.operations.append("openSettings") }
        )
    }

    private func checkFailure() throws {
        if fails {
            throw NSError(domain: "LoginItemControllerTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Test service unavailable."])
        }
    }
}
