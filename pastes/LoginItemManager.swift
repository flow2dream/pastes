import Combine
import ServiceManagement

@MainActor
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}

@MainActor
final class LoginItemManager: ObservableObject {
    static let shared = LoginItemManager(service: SMAppService.mainApp)

    @Published private(set) var status: SMAppService.Status
    @Published private(set) var errorMessage: String?
    private let service: any LoginItemService

    var isRequested: Bool { status == .enabled || status == .requiresApproval }

    init(service: any LoginItemService) {
        self.service = service
        status = service.status
    }

    func refresh() {
        status = service.status
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }
}
