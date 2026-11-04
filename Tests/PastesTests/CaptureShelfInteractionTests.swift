import AppKit
import Testing
@testable import pastes

@Suite("Shelf hover and transparent margins", .serialized)
struct CaptureShelfInteractionTests {
    private let bounds = CGRect(x: 0, y: 0, width: 1440, height: 210)
    private let photos = [
        CGRect(x: 360, y: 25, width: 140, height: 90),
        CGRect(x: 535, y: 25, width: 100, height: 110),
        CGRect(x: 710, y: 25, width: 140, height: 90)
    ]

    @Test
    func theBlankStripBelowThePhotosIsNotPartOfTheShelf() {
        let region = CaptureShelfInteractionRegion(bounds: bounds, photoRects: photos, controlRects: [])
        for point in [CGPoint(x: 220, y: 160), CGPoint(x: 600, y: 180), CGPoint(x: 1200, y: 205)] {
            #expect(!region.keepsOpen(at: point))
            #expect(!region.receivesMouse(at: point, scrolling: false))
        }
    }

    @Test
    func theTopEdgeAndGapsBetweenPhotosRemainAContinuousEntryPath() {
        let region = CaptureShelfInteractionRegion(bounds: bounds, photoRects: photos, controlRects: [], topCorridorMinY: -24)
        #expect(region.keepsOpen(at: CGPoint(x: 720, y: -12)))
        #expect(region.keepsOpen(at: CGPoint(x: 720, y: 5)))
        #expect(region.keepsOpen(at: CGPoint(x: 520, y: 80)))
        #expect(region.keepsOpen(at: CGPoint(x: 590, y: 130)))
        #expect(!region.receivesMouse(at: CGPoint(x: 720, y: -12), scrolling: true))
        #expect(!region.receivesMouse(at: CGPoint(x: 520, y: 80), scrolling: false))
        #expect(region.receivesMouse(at: CGPoint(x: 590, y: 100), scrolling: false))
    }

    @Test
    func lowerCaptureAndNavigationControlsDoNotKeepTheWholeLowerStripOpen() {
        let capture = CGRect(x: 1394, y: 167, width: 36, height: 36)
        let navigation = CGRect(x: 600, y: 172, width: 240, height: 26)
        let region = CaptureShelfInteractionRegion(bounds: bounds, photoRects: photos, controlRects: [capture, navigation])
        for point in [CGPoint(x: 1412, y: 185), CGPoint(x: 720, y: 185)] {
            #expect(region.keepsOpen(at: point))
            #expect(region.receivesMouse(at: point, scrolling: false))
        }
        for point in [CGPoint(x: 400, y: 185), CGPoint(x: 1000, y: 185)] {
            #expect(!region.keepsOpen(at: point))
            #expect(!region.receivesMouse(at: point, scrolling: true))
        }
    }

    @Test
    func overflowingPhotosReceiveScrollInTheirGapsButNotTheBlankStrip() {
        let region = CaptureShelfInteractionRegion(bounds: bounds, photoRects: photos, controlRects: [])
        let gap = CGPoint(x: 520, y: 80)
        #expect(region.receivesMouse(at: gap, scrolling: true))
        #expect(!region.receivesMouse(at: gap, scrolling: false))
        #expect(!region.receivesMouse(at: CGPoint(x: 520, y: 180), scrolling: true))
        #expect(!region.keepsOpen(at: CGPoint(x: 520, y: 180)))
    }

    @Test
    func anEmptyShelfKeepsItsCapturePillReachableWithoutCapturingItsLowerMargin() {
        let pill = CGRect(x: 620, y: 35, width: 200, height: 30)
        let region = CaptureShelfInteractionRegion(bounds: bounds, photoRects: [], controlRects: [pill], topCorridorMinY: -24)
        #expect(region.keepsOpen(at: CGPoint(x: 720, y: -10)))
        #expect(region.keepsOpen(at: CGPoint(x: 720, y: 25)))
        #expect(region.keepsOpen(at: CGPoint(x: 720, y: 50)))
        #expect(region.receivesMouse(at: CGPoint(x: 720, y: 50), scrolling: false))
        #expect(!region.keepsOpen(at: CGPoint(x: 720, y: 180)))
        #expect(!region.receivesMouse(at: CGPoint(x: 720, y: 180), scrolling: false))
    }

    @Test
    func offscreenPortraitsDoNotExtendTheVisibleRowsHoverBoundary() {
        let region = CaptureShelfInteractionRegion(bounds: bounds,
            photoRects: [CGRect(x: 500, y: 25, width: 140, height: 85),
                         CGRect(x: -200, y: 25, width: 100, height: 180),
                         CGRect(x: 1500, y: 25, width: 100, height: 180)], controlRects: [])
        #expect(region.keepsOpen(at: CGPoint(x: 700, y: 100)))
        #expect(!region.keepsOpen(at: CGPoint(x: 700, y: 160)))
        #expect(!region.receivesMouse(at: CGPoint(x: 700, y: 160), scrolling: true))
    }

    @Test
    func anotherScreensHorizontalOriginAndTheWindowsBottomAreRespected() {
        let shifted = CGRect(x: -1440, y: 0, width: 1440, height: 210)
        let region = CaptureShelfInteractionRegion(bounds: shifted,
            photoRects: [CGRect(x: -940, y: 25, width: 140, height: 85)],
            controlRects: [CGRect(x: -60, y: 195, width: 40, height: 40)], topCorridorMinY: -24)
        #expect(region.keepsOpen(at: CGPoint(x: -700, y: 60)))
        #expect(!region.keepsOpen(at: CGPoint(x: 100, y: 60)))
        #expect(!region.keepsOpen(at: CGPoint(x: -700, y: 180)))
        #expect(region.keepsOpen(at: CGPoint(x: -40, y: 205)))
        #expect(!region.keepsOpen(at: CGPoint(x: -40, y: 215)))
        #expect(!region.receivesMouse(at: CGPoint(x: -40, y: 215), scrolling: true))
    }

    /// Run these real-window checks separately from the other opt-in window suites.
    /// They inject coordinates and time, never move the user's pointer or register shortcuts.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PASTES_CAPTURE_HOVER_DISMISS_CHECK"] == "1"))
    @MainActor
    func hiddenShelfDoesNotOpenAfterDwellingAtAnyScreenTopOrEnteringAgain() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        #expect(!fixture.panel.isVisible && !fixture.controller.lineRevealed)
        fixture.assertTopEdgeDoesNotReveal(at: Date())
        await Task.yield()
        #expect(!fixture.panel.isVisible && !fixture.controller.lineRevealed)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PASTES_CAPTURE_HOVER_DISMISS_CHECK"] == "1"))
    @MainActor
    func shortcutToggleOpensAndClosesWithoutTopEdgeReopeningDuringOrAfterDismissal() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        // Invoke the same action registered by the global shortcut without
        // reserving a real key combination in the user's desktop session.
        fixture.shelf.toggle()
        try await fixture.waitUntilRevealed()
        fixture.shelf.toggle()
        #expect(!fixture.controller.lineRevealed)
        fixture.assertTopEdgeDoesNotReveal(at: Date())
        await Task.yield()
        #expect(!fixture.controller.lineRevealed)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!fixture.panel.isVisible)
        fixture.assertTopEdgeDoesNotReveal(at: Date().addingTimeInterval(30))
        await Task.yield()
        #expect(!fixture.panel.isVisible && !fixture.controller.lineRevealed)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PASTES_CAPTURE_HOVER_DISMISS_CHECK"] == "1"))
    @MainActor
    func screenshotSuppressesShortcutAndTopEdgeDoesNotReopenAfterCancellation() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        fixture.shelf.toggle()
        try await fixture.waitUntilRevealed()
        fixture.shelf.setScreenshotActive(true)
        #expect(!fixture.panel.isVisible && !fixture.controller.lineRevealed)
        fixture.shelf.toggle()
        fixture.assertTopEdgeDoesNotReveal(at: Date())
        await Task.yield()
        #expect(!fixture.panel.isVisible && !fixture.controller.lineRevealed)
        // Finishing or cancelling without an imported image has the same
        // inactive transition and must not restore a passive top-edge reveal.
        fixture.shelf.setScreenshotActive(false)
        fixture.assertTopEdgeDoesNotReveal(at: Date().addingTimeInterval(30))
        await Task.yield()
        #expect(!fixture.panel.isVisible && !fixture.controller.lineRevealed)
        fixture.shelf.toggle()
        try await fixture.waitUntilRevealed()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PASTES_CAPTURE_HOVER_DISMISS_CHECK"] == "1"))
    @MainActor
    func stayingOverALowerControlThenMovingIntoTheBlankStripDismissesTheWindow() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try await fixture.show(itemCount: 1)
        let now = Date().addingTimeInterval(10)
        let control = fixture.screenPoint(CGPoint(x: fixture.panel.frame.width - 28, y: 185))
        fixture.shelf.updateHover(at: control, now: now)
        fixture.shelf.updateHover(at: control, now: now.addingTimeInterval(10))
        #expect(fixture.controller.lineRevealed && !fixture.panel.ignoresMouseEvents)
        let blank = fixture.screenPoint(CGPoint(x: fixture.panel.frame.width / 2, y: 180))
        fixture.shelf.updateHover(at: blank, now: now.addingTimeInterval(11))
        #expect(fixture.controller.lineRevealed && fixture.panel.ignoresMouseEvents)
        fixture.shelf.updateHover(at: blank, now: now.addingTimeInterval(11.4))
        #expect(fixture.controller.lineRevealed)
        fixture.shelf.updateHover(at: blank, now: now.addingTimeInterval(11.8))
        #expect(!fixture.controller.lineRevealed)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!fixture.panel.isVisible)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PASTES_CAPTURE_HOVER_DISMISS_CHECK"] == "1"))
    @MainActor
    func overflowDoesNotMakeTheLowerTransparentAreaCaptureEventsOrBlockDismissal() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let capacity = CaptureLineLayout.adaptiveCapacity(width: NSScreen.main?.visibleFrame.width ?? 1440)
        try await fixture.show(itemCount: capacity + 2)
        #expect(CaptureLineLayout.overflow(itemCount: fixture.library.visibleItems.count, width: fixture.panel.frame.width) > 0)
        let blank = fixture.screenPoint(CGPoint(x: fixture.panel.frame.width / 2, y: 180))
        let now = Date().addingTimeInterval(10)
        fixture.shelf.updateHover(at: blank, now: now)
        #expect(fixture.panel.ignoresMouseEvents && fixture.controller.lineRevealed)
        fixture.shelf.updateHover(at: blank, now: now.addingTimeInterval(0.8))
        #expect(!fixture.controller.lineRevealed)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!fixture.panel.isVisible)
    }

    @MainActor private final class Fixture {
        let root: URL
        let domain: String
        let defaults: UserDefaults
        let board: NSPasteboard
        let library: CaptureLibrary
        let controller: CaptureController
        let shelf: CaptureShelfPanel
        let panel: NSWindow

        init() throws {
            _ = NSApplication.shared
            root = FileManager.default.temporaryDirectory.appendingPathComponent("Pastes-HoverDismiss-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            domain = "Pastes-HoverDismiss-\(UUID())"
            defaults = try #require(UserDefaults(suiteName: domain))
            defaults.set(true, forKey: "captureShelfEnabled")
            defaults.set(10000, forKey: "captureMaximumItems")
            board = NSPasteboard.withUniqueName()
            let store = try ClipboardStore(url: root.appendingPathComponent("history.sqlite"))
            library = try CaptureLibrary(directory: root.appendingPathComponent("Library"))
            let session = ClipboardSession(store: store, pasteboard: board, defaults: defaults)
            controller = CaptureController(library: library, session: session, defaults: defaults)
            let previous = Set(NSApplication.shared.windows.map(\.windowNumber))
            shelf = CaptureShelfPanel(controller: controller)
            controller.shelf = shelf
            panel = try #require(NSApplication.shared.windows.first { !previous.contains($0.windowNumber) && $0 is NSPanel })
        }

        func show(itemCount: Int) async throws {
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 12,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let bytes = try #require(bitmap.bitmapData)
            for y in 0..<12 { for x in 0..<20 {
                let offset = y * bitmap.bytesPerRow + x * 4
                bytes[offset] = 0; bytes[offset + 1] = 170; bytes[offset + 2] = 255; bytes[offset + 3] = 255
            } }
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            for index in 0..<itemCount {
                _ = try library.importImage(png, title: "Dismiss fixture \(index)", forceNew: true)
            }
            shelf.show()
            for _ in 0..<50 {
                if controller.lineRevealed { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(controller.lineRevealed && panel.isVisible)
            // Confirm the live SwiftUI tree publishes lower controls separately
            // from photos before fixing coordinates for the timing assertions.
            let captureCenter = CGPoint(x: panel.frame.width - 28, y: 185)
            for _ in 0..<90 {
                if !shelf.hitRects.isEmpty && shelf.controlRects.contains(where: { $0.contains(captureCenter) }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(!shelf.hitRects.isEmpty)
            #expect(shelf.controlRects.contains { $0.contains(captureCenter) })
            let item = try #require(library.visibleItems.first)
            // Fixed geometry isolates the red-strip regression from layout timing.
            shelf.hitRects = [item.id: CGRect(x: 200, y: 25, width: 140, height: 105)]
            shelf.controlRects = [CGRect(x: panel.frame.width - 46, y: 167, width: 36, height: 36)]
        }

        func screenPoint(_ local: CGPoint) -> CGPoint {
            CGPoint(x: panel.frame.minX + local.x, y: panel.frame.maxY - local.y)
        }

        func waitUntilRevealed() async throws {
            for _ in 0..<100 {
                if controller.lineRevealed && panel.isVisible { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(controller.lineRevealed && panel.isVisible)
        }

        func assertTopEdgeDoesNotReveal(at start: Date) {
            for (index, screen) in NSScreen.screens.enumerated() {
                let frame = screen.frame
                let screenStart = start.addingTimeInterval(Double(index) * 60)
                for x in [frame.minX + 1, frame.midX, frame.maxX - 1] {
                    let edge = CGPoint(x: x, y: frame.maxY - 2)
                    for seconds in [0.0, 0.5, 2.0, 10.0] {
                        shelf.updateHover(at: edge, now: screenStart.addingTimeInterval(seconds))
                        #expect(!controller.lineRevealed)
                    }
                    shelf.updateHover(at: CGPoint(x: frame.midX, y: frame.midY),
                        now: screenStart.addingTimeInterval(11))
                    shelf.updateHover(at: edge, now: screenStart.addingTimeInterval(12))
                    shelf.updateHover(at: edge, now: screenStart.addingTimeInterval(20))
                    #expect(!controller.lineRevealed)
                }
            }
        }

        func cleanup() {
            controller.stop()
            controller.shelf = nil
            panel.close()
            board.releaseGlobally()
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
