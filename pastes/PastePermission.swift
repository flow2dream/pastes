import Combine
import CoreGraphics

/// Keyboard event permission is separate from permission to inspect AX elements.
@MainActor
enum PastePermission {
    private static var didRequest = false

    static var isGranted: Bool { CGPreflightPostEventAccess() }

    @discardableResult
    static func requestIfNeeded() -> Bool {
        guard !isGranted else { return true }
        guard !didRequest else { return false }
        didRequest = true
        return CGRequestPostEventAccess()
    }
}

@MainActor
final class PasteFeedback: ObservableObject {
    static let shared = PasteFeedback()
    @Published var needsPermission = false
}
