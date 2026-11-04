import AppKit

/// Reveal on demand in the active Space, without replicating the overlay into every Space.
/// In particular, stationary/all-Spaces windows can be composited over the incoming desktop
/// before activeSpaceDidChange arrives during a trackpad swipe.
@MainActor
enum CaptureOverlayPolicy {
    static func configure(_ panel: NSPanel) {
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
    }
}
