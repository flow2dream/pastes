import AppKit
import Testing
@testable import pastes

@Suite("Shelf Space policy")
struct CaptureOverlayPolicyTests {
    @Test @MainActor
    func overlayWindowsBelongToOneSpaceAndMoveOnlyWhenOrderedIn() {
        _ = NSApplication.shared
        let window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        CaptureOverlayPolicy.configure(window)
        #expect(!window.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(!window.collectionBehavior.contains(.stationary))
        #expect(window.collectionBehavior.contains(.moveToActiveSpace))
        #expect(window.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(window.collectionBehavior.contains(.transient))
        #expect(window.animationBehavior == .none)
        window.close()
    }
}
