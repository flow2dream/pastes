import AppKit
import Testing
@testable import pastes

@Suite("Shelf preview eligibility", .serialized)
struct CaptureHoverPreviewTests {
    @Test @MainActor
    func statusMenusAndNestedMenusBlockPreviewUntilAllTrackingEnds() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let shelf = CaptureShelfPanel(controller: fixture.controller)
        defer { shelf.stop() }
        let menu = NSMenu(), submenu = NSMenu()
        let center = NotificationCenter.default
        defer {
            center.post(name: NSMenu.didEndTrackingNotification, object: submenu)
            center.post(name: NSMenu.didEndTrackingNotification, object: menu)
        }
        #expect(shelf.allowsHoverPreview)
        shelf.hoveredItem = UUID()
        center.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        #expect(!shelf.allowsHoverPreview && shelf.hoveredItem == nil)
        // Repeated begin notifications must not require unmatched extra ends.
        center.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        center.post(name: NSMenu.didBeginTrackingNotification, object: submenu)
        center.post(name: NSMenu.didEndTrackingNotification, object: menu)
        #expect(!shelf.allowsHoverPreview)
        center.post(name: NSMenu.didEndTrackingNotification, object: submenu)
        #expect(shelf.allowsHoverPreview)
        center.post(name: NSMenu.didEndTrackingNotification, object: menu)
        #expect(shelf.allowsHoverPreview)

        shelf.menuOpen = true
        #expect(!shelf.allowsHoverPreview)
        shelf.setScreenshotActive(true)
        shelf.menuOpen = false
        #expect(!shelf.allowsHoverPreview)
        shelf.setScreenshotActive(false)
        shelf.isDragging = true
        #expect(!shelf.allowsHoverPreview)
        shelf.isDragging = false
        #expect(shelf.allowsHoverPreview)
    }

    @Test @MainActor
    func genuineHoverShowsAPassivePreviewAndHideRequiresANewDwell() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let item = try fixture.library.importImage(png(), title: "Hover fixture")
        let preview = CaptureHoverPreview(); defer { preview.hide() }
        func update() {
            preview.update(item: item, url: fixture.library.url(for: item), anchor: anchor,
                           screen: offscreen, isStillHovering: { true })
        }
        update()
        #expect(!preview.isVisible)
        try await Task.sleep(for: .milliseconds(480))
        update()
        try await waitUntil { preview.isVisible }
        #expect(preview.isVisible)
        preview.hide()
        #expect(!preview.isVisible)
        update()
        // A new hover starts from zero instead of retaining the old dwell.
        #expect(!preview.isVisible)
        try await Task.sleep(for: .milliseconds(480))
        update()
        try await waitUntil { preview.isVisible }
        #expect(preview.isVisible)
    }

    @Test @MainActor
    func losingActualHoverDuringDecodeDoesNotShowAndCanStartAgain() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let item = try fixture.library.importImage(png(), title: "Decode race fixture")
        let preview = CaptureHoverPreview(); defer { preview.hide() }
        var isHovering = true
        var eligibilityChecks = 0
        func update() {
            preview.update(item: item, url: fixture.library.url(for: item), anchor: anchor,
                           screen: offscreen, isStillHovering: {
                eligibilityChecks += 1
                return isHovering
            })
        }
        update()
        try await Task.sleep(for: .milliseconds(480))
        update()
        #expect(eligibilityChecks == 2 && !preview.isVisible)
        // The decoding task cannot run on the main actor until this turn yields.
        // Simulate a menu or covering window taking the pointer in that interval.
        isHovering = false
        try await waitUntil { eligibilityChecks >= 3 }
        #expect(!preview.isVisible)

        isHovering = true
        update()
        #expect(!preview.isVisible)
        try await Task.sleep(for: .milliseconds(480))
        update()
        try await waitUntil { preview.isVisible }
        #expect(preview.isVisible)
    }

    private var offscreen: CGRect { CGRect(x: -10000, y: -10000, width: 1000, height: 800) }
    private var anchor: CGRect { CGRect(x: -9600, y: -9350, width: 136, height: 104) }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<40 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    @MainActor private func png() throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 12,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try #require(bitmap.bitmapData)
        for y in 0..<12 { for x in 0..<20 {
            let offset = y * bitmap.bytesPerRow + x * 4
            pixels[offset] = 255; pixels[offset + 1] = 0
            pixels[offset + 2] = 0; pixels[offset + 3] = 255
        } }
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @MainActor private final class Fixture {
        let root: URL
        let domain: String
        let defaults: UserDefaults
        let board: NSPasteboard
        let library: CaptureLibrary
        let controller: CaptureController

        init() throws {
            _ = NSApplication.shared
            root = FileManager.default.temporaryDirectory.appendingPathComponent("Pastes-HoverPreview-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            domain = "Pastes-HoverPreview-\(UUID())"
            defaults = try #require(UserDefaults(suiteName: domain))
            board = NSPasteboard.withUniqueName()
            let store = try ClipboardStore(url: root.appendingPathComponent("history.sqlite"))
            library = try CaptureLibrary(directory: root.appendingPathComponent("Library"))
            let session = ClipboardSession(store: store, pasteboard: board, defaults: defaults)
            controller = CaptureController(library: library, session: session, defaults: defaults)
        }

        func cleanup() {
            controller.stop()
            board.releaseGlobally()
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
