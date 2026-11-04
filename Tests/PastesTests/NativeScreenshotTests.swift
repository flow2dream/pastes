import AppKit
import Testing
@testable import pastes

@Suite("Native screenshots", .serialized)
struct NativeScreenshotTests {
    @Test func reversedDragClipsToTheStartingDisplay() {
        let screen = CGRect(x: -1280, y: -200, width: 1280, height: 800)
        let result = ScreenshotGeometry.selection(from: CGPoint(x: -100, y: 500), to: CGPoint(x: -1500, y: -500), in: screen)
        #expect(result == CGRect(x: -1280, y: -200, width: 1180, height: 700))
        #expect(ScreenshotGeometry.selection(from: .zero, to: CGPoint(x: 1, y: 1), in: CGRect(x: 0, y: 0, width: 100, height: 100)) == nil)
    }

    @Test func retinaCropUsesTopLeftPixelsAndPreservesSourceCenter() throws {
        let screen = CGRect(x: -1440, y: 100, width: 1440, height: 900)
        let selection = CGRect(x: -1240, y: 700, width: 400, height: 200)
        let size = CGSize(width: 2880, height: 1800)
        let pixels = try #require(ScreenshotGeometry.pixels(for: selection, screen: screen, imageSize: size))
        #expect(pixels == CGRect(x: 400, y: 200, width: 800, height: 400))
        #expect(ScreenshotGeometry.sourceRect(for: pixels, screen: screen, imageSize: size) == selection)
        #expect(ScreenshotGeometry.pixels(for: screen, screen: screen, imageSize: size) == CGRect(origin: .zero, size: size))
    }

    @Test @MainActor
    func croppedPNGContainsSelectedPixelsWithoutOverlayAndMatchesNativeResolution() throws {
        let frame = try fixture()
        let result = try frame.crop(CGRect(x: -100, y: 220, width: 20, height: 10))
        let rep = try #require(NSBitmapImageRep(data: result.data))
        #expect(rep.pixelsWide == 40)
        #expect(rep.pixelsHigh == 20)
        let color = try #require(rep.colorAt(x: 10, y: 10)?.usingColorSpace(.deviceRGB))
        #expect(color.redComponent > 0.9)
        #expect(color.blueComponent < 0.1)
        #expect(result.origin == CGRect(x: -100, y: 220, width: 20, height: 10))
        let bottom = try frame.crop(CGRect(x: -100, y: 200, width: 20, height: 10))
        let bottomRep = try #require(NSBitmapImageRep(data: bottom.data))
        let bottomColor = try #require(bottomRep.colorAt(x: 10, y: 10)?.usingColorSpace(.deviceRGB))
        #expect(bottomColor.blueComponent > 0.9)
        #expect(throws: (any Error).self) { try frame.crop(.zero) }
    }

    @Test @MainActor
    func pinnedImageEditingReusesSelectionCanvasAndKeepsOriginalPixels() async throws {
        let source = try fixture()
        let data = try source.crop(source.screen).data
        let origin = CGRect(x: 120, y: 180, width: 320, height: 320)
        let capture = ScreenshotFrame(screen: CGRect(x: 0, y: 0, width: 1000, height: 800), image: source.image)
        var pins = 0, copies = 0, cancellations = 0
        let view = ScreenshotSelectionView(frame: capture.screen, capture: capture,
            onSelection: { _ in copies += 1 }, onCancel: { cancellations += 1 }, onPin: { _ in pins += 1 })
        view.prepareImageEditing(data: data, origin: origin)
        #expect(view.subviews.contains { $0 is ImageAnnotationCanvas })
        #expect(view.selection == origin)
        #expect(try view.outputOrigin() == origin)
        view.beginSelection(at: .zero)
        view.finishSelection(at: CGPoint(x: 600, y: 500))
        #expect(view.selection == origin)
        let output = try #require(NSBitmapImageRep(data: view.exportPNG()))
        #expect(output.pixelsWide == 80 && output.pixelsHigh == 80)
        #expect(pins == 0 && copies == 0)
        if let path = ProcessInfo.processInfo.environment["PASTES_CAPTURE_SNAPSHOT_ROOT"] {
            let window = NSWindow(contentRect: capture.screen, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view
            defer { window.close() }
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("pinned-image-inline-editor.png"))
        }
        view.confirmPin()
        #expect(pins == 1 && copies == 0)
        view.cancelOperation(nil)
        #expect(cancellations == 1)
    }

    @Test @MainActor
    func onlyOnePinnedImageCanBeSelectedAndUnselectedImagesCannotZoom() {
        let first = CaptureReferencePanel(contentRect: CGRect(x: 100, y: 100, width: 424, height: 224), styleMask: [.borderless], backing: .buffered, defer: false)
        let second = CaptureReferencePanel(contentRect: CGRect(x: 500, y: 100, width: 424, height: 224), styleMask: [.borderless], backing: .buffered, defer: false)
        first.isReleasedWhenClosed = false; second.isReleasedWhenClosed = false
        defer { first.close(); second.close() }
        first.acceptsImageZoom = true; second.acceptsImageZoom = true
        let original = first.frame
        first.applyMagnification(0.2)
        first.finishZoom()
        #expect(first.frame == original)
        first.selectImage()
        #expect(first.isImageSelected)
        first.resignKey()
        #expect(first.isImageSelected)
        first.applyMagnification(0.2)
        first.finishZoom()
        #expect(first.frame.width > original.width)
        second.selectImage()
        #expect(!first.isImageSelected && second.isImageSelected)
        second.deselectImage()
        let frame = second.frame
        second.applyMagnification(0.2)
        second.finishZoom()
        #expect(second.frame == frame)
        first.selectImage(); first.orderOut(nil)
        #expect(!first.isImageSelected)
    }

    @Test @MainActor
    func selectedNativeWindowImmediatelyShrinksWithoutLosingSubpixelScale() async throws {
        let panel = CaptureReferencePanel(contentRect: CGRect(x: 100, y: 100, width: 424, height: 224), styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; defer { panel.close() }
        panel.minSize = CGSize(width: 48, height: 48)
        panel.contentView = CaptureReferenceSurface(image: NSImage(size: CGSize(width: 400, height: 200)), frame: CGRect(origin: .zero, size: panel.frame.size))
        panel.acceptsImageZoom = true; panel.selectImage()
        panel.applyMagnification(-0.5)
        #expect(panel.frame.width < 300)
        panel.finishZoom()
        #expect(abs(panel.frame.width - 224) < 0.1)
        #expect(abs(panel.frame.height - 124) < 0.1)
        for _ in 0..<10 { panel.applyMagnification(0.02) }
        panel.finishZoom()
        // AppKit rounds window frames to backing pixels.
        #expect(abs(panel.frame.width - (200 * pow(1.02, 10) + 24)) <= 1)
        panel.applyMagnification(-0.2)
        let stopped = panel.frame
        panel.deselectImage()
        #expect(panel.frame == stopped)
        try await Task.sleep(for: .milliseconds(50))
        #expect(panel.frame == stopped)
    }

    @Test @MainActor
    func deselectingDoesNotJumpAndReselectingKeepsCurrentSize() {
        let panel = CaptureReferencePanel(contentRect: CGRect(x: 100, y: 100, width: 424, height: 224), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; defer { panel.close() }
        panel.acceptsImageZoom = true; panel.selectImage()
        let original = panel.frame
        panel.applyMagnification(0.4)
        let enlarged = panel.frame
        #expect(enlarged.width > original.width)
        panel.deselectImage()
        #expect(panel.frame == enlarged)
        panel.finishZoom()
        #expect(panel.frame == enlarged)
        panel.selectImage()
        panel.applyMagnification(-0.25)
        panel.selectImage()
        panel.finishZoom()
        #expect(abs(panel.frame.width - ((enlarged.width - 24) * 0.75 + 24)) <= 1)
    }

    @Test @MainActor
    func ordinaryAndCommandScrollDoNotResizePinnedWindow() throws {
        let panel = CaptureReferencePanel(contentRect: CGRect(x: 100, y: 100, width: 424, height: 224), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; defer { panel.close() }
        let view = CaptureReferenceDragView(frame: panel.contentLayoutRect)
        panel.contentView = view
        let before = panel.frame
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 2, wheel2: 0, wheel3: 0))
        view.scrollWheel(with: try #require(NSEvent(cgEvent: cg)))
        panel.finishZoom()
        #expect(panel.frame == before)
        panel.acceptsImageZoom = true; panel.selectImage()
        cg.flags = .maskCommand
        view.scrollWheel(with: try #require(NSEvent(cgEvent: cg)))
        panel.finishZoom()
        #expect(panel.frame == before)
    }

    @Test @MainActor
    func scaleGeometryPreservesTheWholeImageAspectRatioAndLimits() {
        let screen = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let original = CGRect(x: -1000, y: 200, width: 424, height: 224)
        let enlarged = CaptureReferenceDragView.scaledFrame(original, delta: 0.1, screen: screen)
        #expect(enlarged.width > original.width && enlarged.height > original.height)
        #expect(abs(enlarged.midX - original.midX) < 0.001)
        #expect(abs(enlarged.midY - original.midY) < 0.001)
        #expect(abs((enlarged.width - 24) / (enlarged.height - 24) - 2) < 0.001)
        let restored = CaptureReferenceDragView.scaledFrame(enlarged, delta: -0.1, screen: screen)
        #expect(abs(restored.width - original.width) < 0.001)
        var limited = enlarged
        let reference = original.insetBy(dx: 12, dy: 12).size
        for _ in 0..<100 {
            limited = CaptureReferenceDragView.scaledFrame(limited, delta: 1, screen: screen, reference: reference)
        }
        #expect(limited.width == reference.width * 4 + 24)
        #expect(limited.width > screen.width)
        #expect(abs(limited.midX - original.midX) < 0.001 && abs(limited.midY - original.midY) < 0.001)
        for _ in 0..<100 {
            limited = CaptureReferenceDragView.scaledFrame(limited, delta: -1, screen: screen, reference: reference)
        }
        #expect(limited.width >= 48 && limited.height >= 48)
        #expect(abs((limited.width - 24) / (limited.height - 24) - 2) < 0.001)
    }

    @Test @MainActor
    func pinRequiresConfirmedSelectionAndDoesNotCopyOrSave() throws {
        let frame = try fixture()
        var pinned: [CGRect] = []
        var copies = 0
        var saves = 0
        let view = ScreenshotSelectionView(frame: CGRect(origin: .zero, size: frame.screen.size), capture: frame,
            onSelection: { _ in copies += 1 }, onCancel: {}, onSave: { _ in saves += 1 },
            onPin: { pinned.append($0) })
        view.confirmPin()
        #expect(pinned.isEmpty)
        view.beginSelection(at: CGPoint(x: -95, y: 210))
        view.finishSelection(at: CGPoint(x: -80, y: 230))
        #expect(pinned.isEmpty)
        view.confirmPin()
        #expect(pinned == [CGRect(x: -95, y: 210, width: 15, height: 20)])
        #expect(copies == 0 && saves == 0)
        let image = try #require(NSBitmapImageRep(data: view.exportPNG()))
        #expect(image.pixelsWide == 30 && image.pixelsHigh == 40)
    }

    @Test @MainActor
    func selectionFinishesOnceAndTinyClicksDoNotComplete() throws {
        let frame = try fixture()
        var results: [CGRect] = []
        var cancellations = 0
        var saves = 0
        let view = ScreenshotSelectionView(frame: CGRect(origin: .zero, size: frame.screen.size), capture: frame,
            onSelection: { results.append($0) }, onCancel: { cancellations += 1 }, onSave: { _ in saves += 1 })
        view.beginSelection(at: CGPoint(x: -80, y: 230))
        view.updateSelection(to: CGPoint(x: -95, y: 210))
        #expect(view.selection == CGRect(x: -95, y: 210, width: 15, height: 20))
        view.finishSelection(at: CGPoint(x: -95, y: 210))
        view.finishSelection(at: CGPoint(x: -90, y: 220))
        #expect(results.isEmpty)
        #expect(saves == 0)
        view.confirmSave()
        #expect(saves == 1)
        #expect(results.isEmpty)
        view.confirmCopy()
        #expect(results.count == 1)
        view.beginSelection(at: CGPoint(x: -95, y: 210))
        view.finishSelection(at: CGPoint(x: -94, y: 211))
        #expect(results.count == 1)
        view.cancelOperation(nil)
        #expect(cancellations == 1)
    }

    @Test @MainActor
    func saveUsesItsOwnCallbackAfterWritingAndDoesNotCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pastes-NativeSave-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try fixture().crop(CGRect(x: -100, y: 210, width: 20, height: 20))
        let destination = root.appendingPathComponent("Screenshot.png")
        var copies = 0, saves = 0
        let screenshot = NativeScreenshot(onActive: { _ in }, onCaptured: { _, _ in copies += 1 },
            onError: { Issue.record("Unexpected capture error: \($0)") }, onSaved: { data, origin in
                let savedData = try Data(contentsOf: destination)
                #expect(savedData == data)
                #expect(data == result.data && origin == result.origin)
                saves += 1
            })
        try screenshot.savePNG(result.data, origin: result.origin, to: destination)
        #expect(copies == 0 && saves == 1)
        let missingDirectory = root.appendingPathComponent("missing/Screenshot.png")
        #expect(throws: (any Error).self) {
            try screenshot.savePNG(result.data, origin: result.origin, to: missingDirectory)
        }
        #expect(copies == 0 && saves == 1)
        #expect(!FileManager.default.fileExists(atPath: missingDirectory.path))
    }

    @Test @MainActor
    func cancellationDuringCaptureIgnoresLateResultsAndDuplicateTriggers() async throws {
        var calls = 0
        var activity: [Bool] = []
        var saved = 0
        var errors = 0
        let screenshot = NativeScreenshot(capture: {
            calls += 1
            try await Task.sleep(for: .milliseconds(200))
            return []
        }, onActive: { activity.append($0) }, onCaptured: { _, _ in saved += 1 }, onError: { _ in errors += 1 })
        screenshot.begin(); screenshot.begin()
        try await Task.sleep(for: .milliseconds(230))
        screenshot.cancel()
        try await Task.sleep(for: .milliseconds(240))
        #expect(calls == 1)
        #expect(activity == [true, false])
        #expect(saved == 0)
        #expect(errors == 0)
        #expect(!screenshot.isActive)
    }

    @Test @MainActor
    func permissionFailureRestoresStateWithoutSaving() async throws {
        var activity: [Bool] = []
        var failed = false
        var saved = false
        let screenshot = NativeScreenshot(capture: { throw NativeScreenshotError.permission },
            onActive: { activity.append($0) }, onCaptured: { _, _ in saved = true }, onError: { _ in failed = true })
        screenshot.begin()
        let deadline = ContinuousClock.now + .seconds(2)
        while screenshot.isActive && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(activity == [true, false])
        #expect(failed)
        #expect(!saved)
    }

    @Test @MainActor
    func nativeResultIsSavedCopiedAndAnimatedFromExactSelectionOnlyOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pastes-NativeCapture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let domain = "Pastes-NativeCapture-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.set(true, forKey: "captureShelfEnabled")
        defaults.set(false, forKey: "captureCopiedImages")
        defer { defaults.removePersistentDomain(forName: domain) }
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let store = try ClipboardStore(url: root.appendingPathComponent("history.sqlite"))
        let session = ClipboardSession(store: store, pasteboard: board, defaults: defaults)
        let library = try CaptureLibrary(directory: root.appendingPathComponent("Library"))
        let controller = CaptureController(library: library, session: session, defaults: defaults)
        let result = try fixture().crop(CGRect(x: -100, y: 210, width: 20, height: 20))
        var externalCopies = 0
        session.monitor.onCopyImage = { _ in externalCopies += 1 }
        try controller.acceptScreenshot(result.data, origin: result.origin)
        let item = try #require(library.visibleItems.first)
        #expect(library.visibleItems.count == 1)
        #expect(library.arrivalOrigins[item.id] == result.origin)
        #expect(store.items.count == 1)
        #expect(item.historyID == store.items[0].id)
        #expect(board.data(forType: .png) == result.data)
        session.monitor.checkPasteboard()
        #expect(externalCopies == 0)
        // Repeated identical screenshots are deliberate, distinct captures.
        try controller.acceptScreenshot(result.data, origin: result.origin)
        #expect(library.visibleItems.count == 2)
        #expect(store.items.count == 2)
        let beforeSaveOnly = board.changeCount
        try controller.acceptScreenshot(result.data, origin: result.origin, copyToClipboard: false)
        #expect(board.changeCount == beforeSaveOnly)
        #expect(library.visibleItems.count == 3)
        let manifest = library.directory.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: true)
        let count = board.changeCount
        #expect(throws: (any Error).self) { try controller.acceptScreenshot(result.data, origin: result.origin) }
        #expect(board.changeCount == count)
        #expect(store.items.count == 3)
        #expect(library.visibleItems.count == 3)
    }

    @Test @MainActor
    func selectionCanBeMovedAndResizedBeforeConfirmation() throws {
        let frame = try fixture()
        var copied: [CGRect] = []
        let view = ScreenshotSelectionView(frame: CGRect(origin: .zero, size: frame.screen.size), capture: frame,
            onSelection: { copied.append($0) }, onCancel: {})
        view.beginSelection(at: CGPoint(x: -100, y: 200))
        view.finishSelection(at: CGPoint(x: -60, y: 240))
        #expect(copied.isEmpty)
        view.beginSelection(at: CGPoint(x: -60, y: 240))
        view.finishSelection(at: CGPoint(x: -70, y: 230))
        #expect(view.selection == CGRect(x: -100, y: 200, width: 30, height: 30))
        view.beginSelection(at: CGPoint(x: -85, y: 215))
        view.finishSelection(at: CGPoint(x: -80, y: 220))
        #expect(view.selection == CGRect(x: -95, y: 205, width: 30, height: 30))
        view.confirmCopy()
        #expect(copied == [CGRect(x: -95, y: 205, width: 30, height: 30)])
    }

    @Test @MainActor
    func copyAndSaveShortcutsOnlyCommitAConfirmedSelection() throws {
        let frame = try fixture()
        var copies = 0, saves = 0
        let view = ScreenshotSelectionView(frame: CGRect(origin: .zero, size: frame.screen.size), capture: frame,
            onSelection: { _ in copies += 1 }, onCancel: {}, onSave: { _ in saves += 1 })
        let copy = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        let save = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1))
        view.confirmCopy(); view.confirmSave()
        #expect(copies == 0 && saves == 0)
        view.beginSelection(at: CGPoint(x: -100, y: 200))
        view.finishSelection(at: CGPoint(x: -60, y: 240))
        #expect(copies == 0 && saves == 0)
        let handledCopy = view.performKeyEquivalent(with: copy)
        let handledSave = view.performKeyEquivalent(with: save)
        #expect(handledCopy && handledSave)
        #expect(copies == 1 && saves == 1)
    }

    @Test @MainActor
    func renderSelectionOffscreen() async throws {
        guard let output = ProcessInfo.processInfo.environment["PASTES_CAPTURE_SNAPSHOT_ROOT"] else { return }
        _ = NSApplication.shared
        let small = try fixture()
        let frame = ScreenshotFrame(screen: CGRect(x: 0, y: 0, width: 1000, height: 600), image: small.image)
        let view = ScreenshotSelectionView(frame: frame.screen, capture: frame, onSelection: { _ in }, onCancel: {})
        view.beginSelection(at: CGPoint(x: 240, y: 420))
        view.finishSelection(at: CGPoint(x: 720, y: 140))
        let window = NSWindow(contentRect: frame.screen, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        view.display()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let factor = CGFloat(bitmap.pixelsWide) / view.bounds.width
        let selected = try #require(bitmap.colorAt(x: Int(500 * factor), y: Int(200 * factor))?.usingColorSpace(.deviceRGB))
        let outside = try #require(bitmap.colorAt(x: Int(100 * factor), y: Int(200 * factor))?.usingColorSpace(.deviceRGB))
        #expect(selected.redComponent > outside.redComponent + 0.15)
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("native-screenshot-selection.png"))
    }

    @MainActor private func fixture() throws -> ScreenshotFrame {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 80,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try #require(rep.bitmapData)
        for y in 0..<80 { for x in 0..<80 {
            let offset = y * rep.bytesPerRow + x * 4
            pixels[offset] = y < 40 ? 255 : 0
            pixels[offset + 1] = 0
            pixels[offset + 2] = y < 40 ? 0 : 255
            pixels[offset + 3] = 255
        } }
        return ScreenshotFrame(screen: CGRect(x: -100, y: 200, width: 40, height: 40), image: try #require(rep.cgImage))
    }
}
