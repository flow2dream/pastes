import AppKit
import Combine
import Testing
@testable import pastes

/// Real NSHostingView/window scheduling check. Never starts global hotkeys,
/// records the screen, moves the pointer, or opens an existing user image.
@Suite("Screenshot and floating-image arrivals", .serialized)
struct CaptureCloseFlightTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PASTES_CAPTURE_CLOSE_FLIGHT_CHECK"] == "1"))
    @MainActor
    func closingAScreenshotStartsItsFlightWithoutManuallyRevealingTheShelf() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let screen = try #require(NSScreen.main)
        let source = CGRect(x: screen.visibleFrame.midX - 160,
                            y: screen.visibleFrame.minY + screen.visibleFrame.height * 0.28,
                            width: 320, height: 180)
        let pinned = try fixture.controller.pinScreenshot(png(), origin: source)
        #expect(!fixture.controller.lineRevealed && fixture.library.items.isEmpty)
        pinned.closeToShelf()
        #expect(!pinned.isVisible)
        let item = try #require(fixture.library.visibleItems.first)
        try await assertAutomaticFlight(fixture: fixture, item: item, source: source)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PASTES_CAPTURE_CLOSE_FLIGHT_CHECK"] == "1"))
    @MainActor
    func closingAnExistingShelfImageAlsoFliesWhileTheShelfIsHidden() async throws {
        let fixture = try Fixture(observeArrivals: false); defer { fixture.cleanup() }
        let item = try fixture.library.importImage(png(), title: "Existing close flight")
        // Mount and render the existing card before hiding the shelf, as in
        // the ordinary "float an image already on the shelf" interaction.
        fixture.shelf.show()
        try await Task.sleep(for: .milliseconds(900))
        #expect(fixture.controller.lineRevealed)
        fixture.observeArrivals()
        let previous = Set(NSApplication.shared.windows.map(\.windowNumber))
        fixture.controller.hold(item)
        let pinned = try #require(NSApplication.shared.windows.compactMap { $0 as? CaptureReferencePanel }
            .first { !previous.contains($0.windowNumber) && $0.title.hasSuffix(" · " + item.title) })
        let screen = try #require(NSScreen.main)
        let source = CGRect(x: screen.visibleFrame.midX - 160,
                            y: screen.visibleFrame.minY + screen.visibleFrame.height * 0.3,
                            width: 320, height: 180)
        pinned.setFrame(source.insetBy(dx: -12, dy: -12), display: true)
        fixture.shelf.hide()
        try await Task.sleep(for: .milliseconds(300))
        #expect(!fixture.controller.lineRevealed)
        pinned.closeToShelf()
        #expect(!pinned.isVisible && fixture.library.visibleItems.count == 1)
        try await assertAutomaticFlight(fixture: fixture, item: item, source: source)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PASTES_CAPTURE_CLOSE_FLIGHT_CHECK"] == "1"))
    @MainActor
    func theSameRenderedShelfItemFliesOnEveryCloseWhileTheShelfStaysRevealed() async throws {
        let fixture = try Fixture(observeArrivals: false); defer { fixture.cleanup() }
        let item = try fixture.library.importImage(png(), title: "Repeat visible-shelf close")
        fixture.shelf.show()
        try await Task.sleep(for: .milliseconds(900))
        #expect(fixture.controller.lineRevealed)
        fixture.observeArrivals()
        let screen = try #require(NSScreen.main)
        var previousArrival = try #require(fixture.library.latestArrival)

        for index in 0..<2 {
            let previousWindows = Set(NSApplication.shared.windows.map(\.windowNumber))
            fixture.controller.hold(item)
            let pinned = try #require(NSApplication.shared.windows.compactMap { $0 as? CaptureReferencePanel }
                .first { !previousWindows.contains($0.windowNumber) && $0.title.hasSuffix(" · " + item.title) })
            let source = CGRect(x: screen.visibleFrame.minX + 150 + CGFloat(index) * 270,
                                y: screen.visibleFrame.minY + screen.visibleFrame.height * 0.32,
                                width: 320, height: 180)
            pinned.setFrame(source.insetBy(dx: -12, dy: -12), display: true)
            // Keep this true across close: only the library arrival token changes.
            // This is the existing-card path that a reveal-only task can miss.
            #expect(fixture.controller.lineRevealed)
            pinned.closeToShelf()
            #expect(!pinned.isVisible && fixture.controller.lineRevealed)
            let arrival = try #require(fixture.library.latestArrival)
            #expect(arrival.itemID == item.id && arrival.token != previousArrival.token)
            #expect(fixture.library.visibleItems.map(\.id) == [item.id])
            try await assertAutomaticFlight(fixture: fixture, item: item, source: source)
            #expect(fixture.library.latestArrival == arrival)
            previousArrival = arrival
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PASTES_CAPTURE_CLOSE_FLIGHT_CHECK"] == "1"))
    @MainActor
    func confirmedScreenshotArrivalWaitsForTheScreenshotOverlayToFinish() async throws {
        try await assertScreenshotArrivalAfterOverlayFinishes(afterSpaceChange: false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PASTES_CAPTURE_CLOSE_FLIGHT_CHECK"] == "1"))
    @MainActor
    func confirmedScreenshotStillRevealsAfterAnEarlierSpaceChange() async throws {
        try await assertScreenshotArrivalAfterOverlayFinishes(afterSpaceChange: true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PASTES_CAPTURE_CLOSE_FLIGHT_CHECK"] == "1"))
    @MainActor
    func ourActivationAndThePreviousAppsDeactivationDoNotCancelTheScreenshotFlight() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let previousApp = try #require(NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.activationPolicy == .regular
        })
        let screen = try #require(NSScreen.main)
        let source = CGRect(x: screen.visibleFrame.midX - 160,
                            y: screen.visibleFrame.minY + screen.visibleFrame.height * 0.3,
                            width: 320, height: 180)
        fixture.shelf.setScreenshotActive(true)
        let item = try fixture.controller.acceptScreenshot(png(), origin: source)
        for _ in 0..<50 {
            if fixture.deliveredArrivals > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(fixture.deliveredArrivals == 1)
        let workspace = NSWorkspace.shared.notificationCenter
        // These local notifications model the paired events when our clipboard
        // gains focus. They do not activate or deactivate any actual app.
        workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        workspace.post(name: NSWorkspace.didDeactivateApplicationNotification, object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: previousApp])
        fixture.shelf.setScreenshotActive(false)
        try await assertAutomaticFlight(fixture: fixture, item: item, source: source)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PASTES_CAPTURE_CLOSE_FLIGHT_CHECK"] == "1"))
    @MainActor
    func anotherAppsActivationStillCancelsAPendingScreenshotArrival() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let otherApp = try #require(NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.activationPolicy == .regular
        })
        fixture.shelf.setScreenshotActive(true)
        _ = try fixture.controller.acceptScreenshot(png(), origin: CGRect(x: 200, y: 300, width: 320, height: 180))
        for _ in 0..<50 {
            if fixture.deliveredArrivals > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(fixture.deliveredArrivals == 1)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification,
            object: nil, userInfo: [NSWorkspace.applicationUserInfoKey: otherApp])
        fixture.shelf.setScreenshotActive(false)
        try await Task.sleep(for: .milliseconds(150))
        #expect(!fixture.controller.lineRevealed && !fixture.hasVisibleWindows)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PASTES_CAPTURE_CLOSE_FLIGHT_CHECK"] == "1"))
    @MainActor
    func aSpaceChangeCancelsAnArrivalWaitingForTheScreenshotOverlay() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        fixture.shelf.setScreenshotActive(true)
        _ = try fixture.controller.acceptScreenshot(png(),
            origin: CGRect(x: 200, y: 300, width: 320, height: 180))
        for _ in 0..<50 {
            if fixture.deliveredArrivals > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.deliveredArrivals == 1 && !fixture.controller.lineRevealed)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification,
                                                  object: nil)
        fixture.shelf.setScreenshotActive(false)
        try await Task.sleep(for: .milliseconds(150))
        #expect(!fixture.controller.lineRevealed && !fixture.hasVisibleWindows)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PASTES_CAPTURE_CLOSE_FLIGHT_CHECK"] == "1"))
    @MainActor
    func anArrivalCapturedBeforeASpaceChangeCannotReopenTheShelfWhenDeliveredLater() async throws {
        let fixture = try Fixture(observeArrivals: false); defer { fixture.cleanup() }
        _ = try fixture.library.importImage(png(), title: "Stale queued arrival",
            origin: CGRect(x: 200, y: 300, width: 320, height: 180))
        let arrival = try #require(fixture.library.latestArrival)
        let queuedRequest = fixture.shelf.arrivalRequest(for: arrival)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification,
                                                  object: nil)
        fixture.shelf.showForArrival(queuedRequest)
        try await Task.sleep(for: .milliseconds(150))
        #expect(!fixture.controller.lineRevealed && !fixture.hasVisibleWindows)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PASTES_CAPTURE_CLOSE_FLIGHT_CHECK"] == "1"))
    @MainActor
    func endingAScreenshotWithoutAnArrivalDoesNotOpenTheShelf() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        fixture.shelf.setScreenshotActive(true)
        fixture.shelf.setScreenshotActive(false)
        try await Task.sleep(for: .milliseconds(150))
        #expect(!fixture.controller.lineRevealed && !fixture.hasVisibleWindows)
        #expect(fixture.library.items.isEmpty && fixture.deliveredArrivals == 0)
    }

    @MainActor private func assertScreenshotArrivalAfterOverlayFinishes(afterSpaceChange: Bool) async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let screen = try #require(NSScreen.main)
        let source = CGRect(x: screen.visibleFrame.midX - 160,
                            y: screen.visibleFrame.minY + screen.visibleFrame.height * 0.3,
                            width: 320, height: 180)
        if afterSpaceChange {
            // Exercise our observer without switching the user's actual Space.
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification,
                                                      object: nil)
        }
        // NativeScreenshot.complete invokes onCaptured before finish/onActive(false).
        // Force its Combine arrival to be delivered in that interval, as a nested
        // UI run loop may do, without capturing the desktop or requesting access.
        fixture.shelf.setScreenshotActive(true)
        let item = try fixture.controller.acceptScreenshot(png(), origin: source)
        for _ in 0..<50 {
            if fixture.deliveredArrivals > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.deliveredArrivals == 1)
        #expect(!fixture.controller.lineRevealed)
        #expect(fixture.library.arrivalOrigins[item.id] == source)
        fixture.shelf.setScreenshotActive(false)
        // No show()/toggle(), pointer movement, or manual shelf reveal follows.
        try await assertAutomaticFlight(fixture: fixture, item: item, source: source)
    }

    @MainActor private func assertAutomaticFlight(fixture: Fixture, item: CaptureItem, source: CGRect) async throws {
        let previousWindows = Set(NSApplication.shared.windows.map(\.windowNumber))
        var flightWindowNumber: Int?
        var frames: [CGRect] = []
        let started = ContinuousClock.now
        for _ in 0..<120 {
            if let flight = NSApplication.shared.windows.first(where: {
                $0.isVisible && $0 is NSPanel && $0.contentView is NSImageView &&
                $0.level.rawValue == NSWindow.Level.floating.rawValue + 1 && $0.ignoresMouseEvents &&
                !previousWindows.contains($0.windowNumber) &&
                (flightWindowNumber == $0.windowNumber ||
                 (flightWindowNumber == nil && abs($0.frame.midX - source.midX) < 8 && abs($0.frame.midY - source.midY) < 8))
            }) {
                flightWindowNumber = flight.windowNumber
                frames.append(flight.frame)
            }
            try await Task.sleep(for: .milliseconds(16))
        }
        let target = fixture.shelf.screenRect(for: item.id)
        print("CLOSE FLIGHT item=\(item.id) token=\(String(describing: fixture.library.arrivalTokens[item.id])) window=\(String(describing: flightWindowNumber)) elapsed=\(started.duration(to: .now)) revealed=\(fixture.controller.lineRevealed) source=\(source) target=\(String(describing: target)) samples=\(frames.count)")
        #expect(fixture.controller.lineRevealed)
        #expect(!frames.isEmpty, "A confirmed arrival must start a real flight without show()/toggle()")
        guard let first = frames.first, let last = frames.last, let target else { return }
        #expect(abs(first.midX - source.midX) < 8 && abs(first.midY - source.midY) < 8)
        #expect(hypot(last.midX - target.midX, last.midY - target.midY) <
                hypot(first.midX - target.midX, first.midY - target.midY) / 3)
    }

    @MainActor private func png() throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 18,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try #require(bitmap.bitmapData)
        for y in 0..<18 { for x in 0..<32 {
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
        let shelf: CaptureShelfPanel
        private let previousWindowNumbers: Set<Int>
        var arrivals: AnyCancellable?
        var deliveredArrivals = 0
        var hasVisibleWindows: Bool {
            NSApplication.shared.windows.contains {
                !previousWindowNumbers.contains($0.windowNumber) && $0.isVisible
            }
        }

        init(observeArrivals: Bool = true) throws {
            _ = NSApplication.shared
            previousWindowNumbers = Set(NSApplication.shared.windows.map(\.windowNumber))
            root = FileManager.default.temporaryDirectory.appendingPathComponent("Pastes-CloseFlight-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            domain = "Pastes-CloseFlight-\(UUID())"
            defaults = try #require(UserDefaults(suiteName: domain))
            defaults.set(true, forKey: "captureShelfEnabled")
            board = NSPasteboard.withUniqueName()
            let store = try ClipboardStore(url: root.appendingPathComponent("history.sqlite"))
            library = try CaptureLibrary(directory: root.appendingPathComponent("Library"))
            let session = ClipboardSession(store: store, pasteboard: board, defaults: defaults)
            controller = CaptureController(library: library, session: session, defaults: defaults)
            shelf = CaptureShelfPanel(controller: controller)
            controller.shelf = shelf
            if observeArrivals { self.observeArrivals() }
        }

        func observeArrivals() {
            // Matches the production subscription while avoiding controller.start()
            // and its process-wide shortcut registrations.
            arrivals = library.$latestArrival.dropFirst().compactMap { $0 }
                .compactMap { [weak self] arrival in self?.shelf.arrivalRequest(for: arrival) }
                .receive(on: DispatchQueue.main)
                .sink { [weak self] request in
                    guard let self, controller.enabled,
                          library.visibleItems.contains(where: { $0.id == request.arrival.itemID }) else { return }
                    deliveredArrivals += 1
                    shelf.showForArrival(request)
                }
        }

        func cleanup() {
            arrivals = nil
            controller.stop()
            controller.shelf = nil
            // stop() normally tucks the shelf after 240ms. The isolated fixture
            // ends now, so close only the windows it created synchronously.
            for window in NSApplication.shared.windows where !previousWindowNumbers.contains(window.windowNumber) {
                window.close()
            }
            board.releaseGlobally()
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
