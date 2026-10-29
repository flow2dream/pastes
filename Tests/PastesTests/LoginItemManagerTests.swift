import Foundation
import ServiceManagement
import Testing
@testable import pastes

@Suite("Login item status")
struct LoginItemManagerTests {
    @Test @MainActor
    func enableAndDisableFollowSystemStatus() {
        let service = FakeLoginItemService()
        let manager = LoginItemManager(service: service)
        #expect(!manager.isRequested)
        manager.setEnabled(true)
        #expect(manager.status == .enabled)
        #expect(manager.isRequested)
        manager.setEnabled(false)
        #expect(manager.status == .notRegistered)
        #expect(!manager.isRequested)
        #expect(manager.errorMessage == nil)
    }

    @Test @MainActor
    func pendingApprovalRemainsVisibleAndCanBeCancelled() {
        let service = FakeLoginItemService()
        service.registrationStatus = .requiresApproval
        let manager = LoginItemManager(service: service)
        manager.setEnabled(true)
        #expect(manager.status == .requiresApproval)
        #expect(manager.isRequested)
        manager.setEnabled(false)
        #expect(manager.status == .notRegistered)
    }

    @Test @MainActor
    func failuresKeepTheActualStateAndExposeTheError() {
        let service = FakeLoginItemService()
        let manager = LoginItemManager(service: service)
        service.shouldFail = true
        manager.setEnabled(true)
        #expect(!manager.isRequested)
        #expect(manager.errorMessage == "Synthetic login item failure")
        service.status = .enabled
        manager.refresh()
        manager.setEnabled(false)
        #expect(manager.isRequested)
        #expect(manager.errorMessage != nil)
    }

    @Test @MainActor
    func externalSystemChangesRefreshWithoutRegisteringAgain() {
        let service = FakeLoginItemService()
        let manager = LoginItemManager(service: service)
        service.status = .enabled
        manager.refresh()
        #expect(manager.isRequested)
        service.status = .notRegistered
        manager.refresh()
        #expect(!manager.isRequested)
        #expect(service.changeCount == 0)
    }
}

@MainActor
private final class FakeLoginItemService: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    var registrationStatus: SMAppService.Status = .enabled
    var shouldFail = false
    var changeCount = 0

    func register() throws {
        if shouldFail { throw SyntheticLoginItemError() }
        changeCount += 1
        status = registrationStatus
    }

    func unregister() throws {
        if shouldFail { throw SyntheticLoginItemError() }
        changeCount += 1
        status = .notRegistered
    }
}

private struct SyntheticLoginItemError: LocalizedError {
    var errorDescription: String? { "Synthetic login item failure" }
}
