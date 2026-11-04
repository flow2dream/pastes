import Foundation

/// Imported media has a transient token; loading history and toggling pins do not.
struct CaptureHangRequest: Equatable {
    var token: UUID?
    var revealed: Bool
    var imageReady: Bool

    func shouldAnimate(after consumed: UUID?) -> Bool {
        guard let token else { return false }
        return revealed && imageReady && token != consumed
    }
}
