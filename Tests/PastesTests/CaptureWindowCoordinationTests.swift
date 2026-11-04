import AppKit
import Combine
import CoreGraphics
import Testing
@testable import pastes

/// Run separately from other opt-in window suites. The real manager owns only
/// fixture windows; capture uses synthetic pixels and never reads the display.
@Suite("Shelf, history and screenshot window coordination", .serialized)
struct CaptureWindowCoordinationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PASTES_CAPTURE_WINDOW_COORDINATION_CHECK"] == "1"))
    @MainActor
    func shelfShortcutDoesNotRestoreSettingsOrHistoryFromAHiddenApplication() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let settings = try await fixture.openSettings()
        try await fixture.showHistory()
        #expect(settings.isVisible && fixture.history.isVisible)
        NSApp.hide(nil)
        try await fixture.waitUntil { NSApp.isHidden }
        #expect(!settings.isVisible && !fixture.history.isVisible)

        // Same action as the shelf shortcut; no actual global key is registered.
        fixture.shelf.toggle()
        try await fixture.waitUntil { fixture.controller.lineRevealed && fixture.shelfWindow.isVisible && !NSApp.isHidden }
        try await Task.sleep(for: .milliseconds(450))
        #expect(!settings.isVisible && !fixture.history.isVisible)
        let onscreen = fixture.onscreenWindowNumbers()
        #expect(onscreen.contains(fixture.shelfWindow.windowNumber))
        #expect(!onscreen.contains(settings.windowNumber))
        #expect(!onscreen.contains(fixture.history.windowNumber))

        // An explicit Settings action must still reopen the same window.
        fixture.manager.openSettings()
        try await fixture.waitUntil { settings.isVisible }
        #expect(settings.isVisible)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PASTES_CAPTURE_WINDOW_COORDINATION_CHECK"] == "1"))
    @MainActor
    func shelfShortcutPreservesSettingsThatAreAlreadyVisibleInAnUnhiddenApplication() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let settings = try await fixture.openSettings()
        #expect(!NSApp.isHidden && settings.isVisible)
        fixture.shelf.toggle()
        try await fixture.waitUntil { fixture.controller.lineRevealed && fixture.shelfWindow.isVisible }
        try await Task.sleep(for: .milliseconds(200))
        #expect(settings.isVisible)
        #expect(fixture.onscreenWindowNumbers().contains(settings.windowNumber))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PASTES_CAPTURE_WINDOW_COORDINATION_CHECK"] == "1"))
    @MainActor
    func screenshotFromVisibleHistoryHidesItBeforeCaptureAndFliesWithoutManualShelfReveal() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try await fixture.showHistory()
        #expect(!fixture.controller.lineRevealed && !fixture.shelfWindow.isVisible)
        fixture.controller.takeScreenshot()
        #expect(!fixture.history.isVisible)
        let selection = try await fixture.waitForSelection()
        #expect(fixture.captureState.calls == 1)
        #expect(fixture.captureState.historyVisibleAtCapture == false)
        #expect(!fixture.history.isVisible)

        let source = fixture.sourceRect
        selection.beginSelection(at: source.origin)
        selection.finishSelection(at: CGPoint(x: source.maxX, y: source.maxY))
        let previousWindows = Set(NSApp.windows.map(\.windowNumber))
        selection.confirmCopy()
        #expect(!fixture.controller.screenshotActive)
        #expect(!fixture.history.isVisible)
        let item = try #require(fixture.library.visibleItems.first)
        #expect(fixture.library.arrivalOrigins[item.id] == source)
        try await fixture.assertAutomaticFlight(for: item, source: source, excluding: previousWindows)
        #expect(fixture.deliveredArrivals == 1)
        #expect(fixture.captureState.calls == 1)
        #expect(!fixture.history.isVisible)
        #expect(!fixture.onscreenWindowNumbers().contains(fixture.history.windowNumber))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PASTES_CAPTURE_WINDOW_COORDINATION_CHECK"] == "1"))
    @MainActor
    func cancellingScreenshotDoesNotRestoreHistoryOrRevealTheShelf() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try await fixture.showHistory()
        fixture.controller.takeScreenshot()
        _ = try await fixture.waitForSelection()
        #expect(fixture.captureState.historyVisibleAtCapture == false)
        fixture.controller.screenshot.cancel()
        try await Task.sleep(for: .milliseconds(450))
        #expect(!fixture.controller.screenshotActive)
        #expect(!fixture.history.isVisible)
        #expect(!fixture.controller.lineRevealed && !fixture.shelfWindow.isVisible)
        #expect(fixture.library.items.isEmpty && fixture.deliveredArrivals == 0)
    }

    @MainActor private final class CaptureState {
        weak var history: NSWindow?
        var calls = 0
        var historyVisibleAtCapture: Bool?
    }

    @MainActor private final class Fixture {
        let root: URL
        let domain: String
        let defaults: UserDefaults
        let board: NSPasteboard
        let library: CaptureLibrary
        let controller: CaptureController
        let shelf: CaptureShelfPanel
        let shelfWindow: NSWindow
        let manager: PanelManager
        let history: NSWindow
        let captureState: CaptureState
        let sourceRect: CGRect
        private let previousWindowNumbers: Set<Int>
        private let previousApplication: NSRunningApplication?
        private var arrivals: AnyCancellable?
        var deliveredArrivals = 0

        init() throws {
            _ = NSApplication.shared
            previousWindowNumbers = Set(NSApp.windows.map(\.windowNumber))
            previousApplication = NSWorkspace.shared.frontmostApplication
            root = FileManager.default.temporaryDirectory.appendingPathComponent("Pastes-WindowCoordination-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            domain = "Pastes-WindowCoordination-\(UUID())"
            defaults = try #require(UserDefaults(suiteName: domain))
            defaults.set(true, forKey: "captureShelfEnabled")
            board = NSPasteboard.withUniqueName()
            let store = try ClipboardStore(url: root.appendingPathComponent("history.sqlite"))
            try store.addText("Window coordination fixture", limit: 20)
            library = try CaptureLibrary(directory: root.appendingPathComponent("Library"))
            let session = ClipboardSession(store: store, pasteboard: board, defaults: defaults)
            let state = CaptureState()
            captureState = state
            let screen = try #require(NSScreen.main)
            let frame = screen.frame
            sourceRect = CGRect(x: frame.midX - 160, y: frame.minY + frame.height * 0.28,
                                width: 320, height: 180).integral
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(frame.width), pixelsHigh: Int(frame.height), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
            let bytes = try #require(bitmap.bitmapData)
            for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
                let offset = y * bitmap.bytesPerRow + x * 4
                bytes[offset] = 30; bytes[offset + 1] = 150; bytes[offset + 2] = 230; bytes[offset + 3] = 255
            } }
            let captured = ScreenshotFrame(screen: frame, image: try #require(bitmap.cgImage))
            controller = CaptureController(library: library, session: session, defaults: defaults,
                screenshotCapture: {
                    state.calls += 1
                    state.historyVisibleAtCapture = state.history?.isVisible
                    return [captured]
                })
            let beforeShelf = Set(NSApp.windows.map(\.windowNumber))
            shelf = CaptureShelfPanel(controller: controller)
            controller.shelf = shelf
            shelfWindow = try #require(NSApp.windows.first { !beforeShelf.contains($0.windowNumber) && $0 is NSPanel })
            manager = PanelManager(store: store, session: session, captures: controller)
            history = try #require(manager.panelWindow)
            state.history = history
            // Mirror production delivery without controller.start() or hotkeys.
            arrivals = library.$latestArrival.dropFirst().compactMap { $0 }
                .compactMap { [weak self] arrival in self?.shelf.arrivalRequest(for: arrival) }
                .receive(on: DispatchQueue.main)
                .sink { [weak self] request in
                    guard let self, self.controller.enabled,
                          self.library.visibleItems.contains(where: { $0.id == request.arrival.itemID }) else { return }
                    self.deliveredArrivals += 1
                    self.shelf.showForArrival(request)
                }
        }

        func openSettings() async throws -> NSWindow {
            let before = Set(NSApp.windows.map(\.windowNumber))
            manager.openSettings()
            let settings = try #require(NSApp.windows.first { !before.contains($0.windowNumber) && !($0 is NSPanel) })
            try await waitUntil { settings.isVisible && !NSApp.isHidden }
            try await Task.sleep(for: .milliseconds(250))
            return settings
        }

        func showHistory() async throws {
            if !history.isVisible { manager.toggle(atMouse: true) }
            try await waitUntil { history.isVisible && !NSApp.isHidden }
            // Let normal app activation settle before starting a transaction.
            try await Task.sleep(for: .milliseconds(250))
        }

        func waitForSelection() async throws -> ScreenshotSelectionView {
            for _ in 0..<150 {
                if let selection = NSApp.windows.filter({ !previousWindowNumbers.contains($0.windowNumber) && $0.isVisible })
                    .compactMap({ $0.contentView as? ScreenshotSelectionView }).first { return selection }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw CoordinationError.selectionDidNotAppear
        }

        func waitUntil(_ predicate: () -> Bool) async throws {
            for _ in 0..<150 {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(predicate())
        }

        func onscreenWindowNumbers() -> Set<Int> {
            let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            return Set(info.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == ProcessInfo.processInfo.processIdentifier }
                .compactMap { $0[kCGWindowNumber as String] as? Int })
        }

        func assertAutomaticFlight(for item: CaptureItem, source: CGRect, excluding previous: Set<Int>) async throws {
            var flightWindow: Int?
            var frames: [CGRect] = []
            for _ in 0..<120 {
                if let window = NSApp.windows.first(where: {
                    !previous.contains($0.windowNumber) && $0.isVisible && $0 is NSPanel && $0.contentView is NSImageView &&
                    $0.level.rawValue == NSWindow.Level.floating.rawValue + 1 && $0.ignoresMouseEvents &&
                    (flightWindow == $0.windowNumber || (flightWindow == nil &&
                     abs($0.frame.midX - source.midX) < 8 && abs($0.frame.midY - source.midY) < 8))
                }) {
                    flightWindow = window.windowNumber
                    frames.append(window.frame)
                }
                try await Task.sleep(for: .milliseconds(16))
            }
            #expect(controller.lineRevealed && shelfWindow.isVisible)
            #expect(frames.count > 1, "Confirmed capture must fly immediately, without manually showing the shelf")
            let target = try #require(shelf.screenRect(for: item.id))
            guard let first = frames.first, let last = frames.last else { return }
            #expect(abs(first.midX - source.midX) < 8 && abs(first.midY - source.midY) < 8)
            #expect(hypot(last.midX - target.midX, last.midY - target.midY) <
                    hypot(first.midX - target.midX, first.midY - target.midY) / 3)
        }

        func cleanup() {
            arrivals = nil
            controller.stop()
            controller.shelf = nil
            for window in NSApp.windows where !previousWindowNumbers.contains(window.windowNumber) { window.close() }
            if NSApp.isHidden { NSApp.unhideWithoutActivation() }
            board.releaseGlobally()
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
               let previousApplication, !previousApplication.isTerminated,
               previousApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previousApplication.activate()
            }
        }
    }

    private enum CoordinationError: Error { case selectionDidNotAppear }
}
