import AppKit
import Testing
@testable import pastes

/// Uses only temporary media and this helper's own windows. No hotkeys, pointer
/// movement, desktop capture, or changes to system accessibility preferences.
@Suite("Take a shelf image down into a floating reference", .serialized)
struct CaptureTakeDownTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PASTES_CAPTURE_TAKE_DOWN_CHECK"] == "1"))
    @MainActor
    func floatingAnImageTravelsFromItsCardAndHandsOffToTheNativeReference() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let item = try await fixture.prepareShelf()
        let source = try #require(fixture.shelf.screenRect(for: item.id)).insetBy(dx: 4, dy: 4)
        let originalItems = fixture.library.items
        let originalHistory = fixture.store.items
        let clipboardGeneration = fixture.board.changeCount
        let previousWindows = Set(NSApplication.shared.windows.map(\.windowNumber))

        fixture.controller.hold(item)
        let reference = try fixture.newReference(for: item, excluding: previousWindows)
        #expect(!fixture.library.shelfItems.contains { $0.id == item.id })
        #expect(!fixture.library.visibleItems.contains { $0.id == item.id })
        // Respect the machine's preference rather than changing it for a test.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            #expect(reference.isVisible && fixture.controller.liftingCaptureIDs.isEmpty)
            #expect(!fixture.library.shelfItems.contains { $0.id == item.id })
            #expect(!fixture.library.visibleItems.contains { $0.id == item.id })
            return
        }
        #expect(!reference.isVisible && fixture.controller.liftingCaptureIDs.contains(item.id))
        #expect(!reference.styleMask.contains(.nonactivatingPanel))
        let destination = reference.frame.insetBy(dx: 12, dy: 12)
        var flight: NSWindow?
        var frames: [CGRect] = []
        for _ in 0..<100 {
            if let current = fixture.flight(excluding: previousWindows) {
                if flight == nil { flight = current }
                if current === flight {
                    frames.append(current.frame)
                    if hypot(current.frame.midX - destination.midX, current.frame.midY - destination.midY) > 4 {
                        #expect(!reference.isVisible, "The native reference should appear only after the travelling image arrives")
                    }
                }
            }
            if reference.isVisible && fixture.controller.liftingCaptureIDs.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let first = try #require(frames.first), last = try #require(frames.last)
        #expect(abs(first.midX - source.midX) < 8 && abs(first.midY - source.midY) < 8)
        #expect(last.width > first.width * 2 && last.height > first.height * 2)
        #expect(hypot(last.midX - destination.midX, last.midY - destination.midY) <
                hypot(first.midX - destination.midX, first.midY - destination.midY) / 4)
        #expect(reference.isVisible && fixture.controller.liftingCaptureIDs.isEmpty)
        #expect(flight?.isVisible == false && fixture.flight(excluding: previousWindows) == nil)
        #expect(!fixture.library.shelfItems.contains { $0.id == item.id })
        #expect(!fixture.library.visibleItems.contains { $0.id == item.id })
        #expect(fixture.library.items == originalItems && fixture.store.items == originalHistory)
        #expect(fixture.board.changeCount == clipboardGeneration)
        #expect(fixture.board.string(forType: .string) == Fixture.clipboardSentinel)
        print("TAKE DOWN source=\(source) destination=\(destination) samples=\(frames.count) nativeVisible=\(reference.isVisible)")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PASTES_CAPTURE_TAKE_DOWN_CHECK"] == "1"))
    @MainActor
    func hidingTheShelfDuringTakeDownCompletesTheFloatWithoutReopeningTheShelf() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let item = try await fixture.prepareShelf()
        let previousWindows = Set(NSApplication.shared.windows.map(\.windowNumber))
        fixture.controller.hold(item)
        let reference = try fixture.newReference(for: item, excluding: previousWindows)
        #expect(!fixture.library.shelfItems.contains { $0.id == item.id })
        #expect(!fixture.library.visibleItems.contains { $0.id == item.id })
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            #expect(reference.isVisible && fixture.controller.liftingCaptureIDs.isEmpty)
            #expect(!fixture.library.shelfItems.contains { $0.id == item.id })
            #expect(!fixture.library.visibleItems.contains { $0.id == item.id })
            return
        }
        let flight = try await fixture.waitForFlight(excluding: previousWindows)
        fixture.shelf.hide()
        #expect(reference.isVisible && !fixture.controller.lineRevealed)
        #expect(!fixture.library.shelfItems.contains { $0.id == item.id })
        #expect(!fixture.library.visibleItems.contains { $0.id == item.id })
        try await Task.sleep(for: .milliseconds(180))
        #expect(!flight.isVisible && fixture.flight(excluding: previousWindows) == nil)
        #expect(reference.isVisible && fixture.controller.liftingCaptureIDs.isEmpty)
        #expect(!fixture.controller.lineRevealed)
        #expect(!fixture.library.shelfItems.contains { $0.id == item.id })
        #expect(!fixture.library.visibleItems.contains { $0.id == item.id })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PASTES_CAPTURE_TAKE_DOWN_CHECK"] == "1"))
    @MainActor
    func closingThePendingReferenceDuringTakeDownNeverResurrectsIt() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let item = try await fixture.prepareShelf()
        let previousWindows = Set(NSApplication.shared.windows.map(\.windowNumber))
        fixture.controller.hold(item)
        let reference = try fixture.newReference(for: item, excluding: previousWindows)
        #expect(!fixture.library.shelfItems.contains { $0.id == item.id })
        #expect(!fixture.library.visibleItems.contains { $0.id == item.id })
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            reference.close()
            #expect(!reference.isVisible && reference.isReferenceFinished)
            #expect(fixture.library.shelfItems.map(\.id) == [item.id])
            #expect(fixture.library.visibleItems.map(\.id) == [item.id])
            return
        }
        let flight = try await fixture.waitForFlight(excluding: previousWindows)
        reference.close()
        try await Task.sleep(for: .milliseconds(650))
        #expect(reference.isReferenceFinished && !reference.isVisible && reference.referenceData == nil)
        #expect(!flight.isVisible && fixture.flight(excluding: previousWindows) == nil)
        #expect(fixture.controller.liftingCaptureIDs.isEmpty)
        #expect(fixture.library.shelfItems.map(\.id) == [item.id])
        #expect(fixture.library.visibleItems.map(\.id) == [item.id])
        fixture.controller.editors.closeAll()
        #expect(!reference.isVisible)
    }

    @MainActor private final class Fixture {
        static let clipboardSentinel = "Preserve clipboard during take down"
        let root: URL
        let domain: String
        let defaults: UserDefaults
        let board: NSPasteboard
        let store: ClipboardStore
        let library: CaptureLibrary
        let controller: CaptureController
        let shelf: CaptureShelfPanel
        private let previousWindowNumbers: Set<Int>

        init() throws {
            _ = NSApplication.shared
            previousWindowNumbers = Set(NSApplication.shared.windows.map(\.windowNumber))
            root = FileManager.default.temporaryDirectory.appendingPathComponent("Pastes-TakeDown-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            domain = "Pastes-TakeDown-\(UUID())"
            defaults = try #require(UserDefaults(suiteName: domain))
            defaults.set(true, forKey: "captureShelfEnabled")
            board = NSPasteboard.withUniqueName()
            board.setString(Self.clipboardSentinel, forType: .string)
            store = try ClipboardStore(url: root.appendingPathComponent("history.sqlite"))
            library = try CaptureLibrary(directory: root.appendingPathComponent("Library"))
            let session = ClipboardSession(store: store, pasteboard: board, defaults: defaults)
            controller = CaptureController(library: library, session: session, defaults: defaults)
            shelf = CaptureShelfPanel(controller: controller)
            controller.shelf = shelf
        }

        func prepareShelf() async throws -> CaptureItem {
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 40,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let pixels = try #require(bitmap.bitmapData)
            for y in 0..<40 { for x in 0..<64 {
                let offset = y * bitmap.bytesPerRow + x * 4
                pixels[offset] = 0; pixels[offset + 1] = 180
                pixels[offset + 2] = 255; pixels[offset + 3] = 255
            } }
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let item = try library.importImage(png, title: "Take down fixture")
            shelf.show()
            try await Task.sleep(for: .milliseconds(900))
            #expect(controller.lineRevealed)
            let source = try #require(shelf.screenRect(for: item.id))
            #expect(source.width > 80 && source.height > 40)
            return item
        }

        func newReference(for item: CaptureItem, excluding previous: Set<Int>) throws -> CaptureReferencePanel {
            try #require(NSApplication.shared.windows.compactMap { $0 as? CaptureReferencePanel }.first {
                !previous.contains($0.windowNumber) && $0.title.hasSuffix(" · " + item.title)
            })
        }

        func flight(excluding previous: Set<Int>) -> NSWindow? {
            NSApplication.shared.windows.first {
                !previous.contains($0.windowNumber) && $0.isVisible && $0 is NSPanel &&
                $0.contentView is NSImageView && $0.ignoresMouseEvents &&
                $0.level.rawValue == NSWindow.Level.floating.rawValue + 1
            }
        }

        func waitForFlight(excluding previous: Set<Int>) async throws -> NSWindow {
            for _ in 0..<60 {
                if let window = flight(excluding: previous) { return window }
                try await Task.sleep(for: .milliseconds(10))
            }
            return try #require(flight(excluding: previous), "Expected a travelling image before the native reference is shown")
        }

        func cleanup() {
            controller.stop()
            controller.shelf = nil
            for window in NSApplication.shared.windows where !previousWindowNumbers.contains(window.windowNumber) {
                window.close()
            }
            board.releaseGlobally()
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
