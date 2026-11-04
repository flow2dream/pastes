import AppKit
import ScreenCaptureKit
import Testing
@testable import pastes

@Suite("Immediate pinned-image zoom", .serialized)
struct CaptureImmediateZoomTests {
    @Test @MainActor
    func constructedSurfaceHasVisibleImageGeometryBeforeAnyLayoutPass() throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 40,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let cgImage = try #require(bitmap.cgImage)
        let frame = CGRect(x: 0, y: 0, width: 424, height: 224)
        let surface = CaptureReferenceSurface(image: cgImage, frame: frame)
        // No window attachment or manual layout: the first compositor commit
        // must already contain an image with nonzero bounds.
        #expect(surface.photoLayer.frame == surface.bounds.insetBy(dx: 12, dy: 12))
        #expect(surface.photoLayer.bounds.width > 0 && surface.photoLayer.bounds.height > 0)
        let contents = try #require(surface.photoLayer.contents)
        #expect(CFGetTypeID(contents as CFTypeRef) == CGImage.typeID)

        let image = NSImage(cgImage: cgImage, size: CGSize(width: 80, height: 40))
        let imageSurface = CaptureReferenceSurface(image: image, frame: frame)
        #expect(imageSurface.photoLayer.frame == imageSurface.bounds.insetBy(dx: 12, dy: 12))
    }

    @Test @MainActor
    func systemRecognizerConsumesEachDeltaOnceAndDoesNotMoveAfterInputStops() async throws {
        let panel = makePanel(); defer { panel.close() }
        let surface = try #require(panel.contentView as? CaptureReferenceSurface)
        let installed = try #require(surface.gestureRecognizers.first as? NSMagnificationGestureRecognizer)
        #expect(surface.gestureRecognizers.count == 1)
        #expect(installed.target === surface && installed.action == #selector(CaptureReferenceDragView.onMagnify(_:)))
        #expect(installed.isEnabled)
        #expect(!surface.allowedTouchTypes.contains(.indirect) && !surface.wantsRestingTouches)
        panel.selectImage()
        #expect(installed.isEnabled && installed.delegate === surface)
        #expect(surface.gestureRecognizerShouldBegin(installed))
        let gesture = SyntheticMagnificationRecognizer(for: surface)
        let deltas: [CGFloat] = [0.1, -0.0001, 0.025, -0.08, -0.0005, 0.04, -0.02]
        var expectedWidth: CGFloat = 400
        for (index, delta) in deltas.enumerated() {
            #expect(gesture.emit(delta, state: index == 0 ? .began : .changed))
            expectedWidth *= 1 + delta
            #expect(gesture.magnification == 0)
            #expect(abs(panel.frame.width - (expectedWidth + 24)) <= 1)
        }
        gesture.emit(-0.01, state: .ended)
        expectedWidth *= 0.99
        #expect(abs(panel.frame.width - (expectedWidth + 24)) <= 1)
        let final = panel.frame
        try await Task.sleep(for: .milliseconds(80))
        #expect(panel.frame == final)
    }

    @Test @MainActor
    func consecutiveSystemGesturesShrinkAndRecoverAfterCancellationOrInvalidInput() throws {
        let panel = makePanel(); defer { panel.close() }
        let surface = try #require(panel.contentView as? CaptureReferenceSurface)
        panel.selectImage()
        let gesture = SyntheticMagnificationRecognizer(for: surface)
        gesture.emit(0.1, state: .began)
        gesture.emit(0.2, state: .ended)
        #expect(abs(panel.frame.width - (400 * 1.1 * 1.2 + 24)) <= 1)
        gesture.emit(-0.25, state: .began)
        gesture.emit(-0.1, state: .ended)
        #expect(abs(panel.frame.width - (400 * 1.1 * 1.2 * 0.75 * 0.9 + 24)) <= 1)
        let shrunk = panel.frame
        gesture.emit(0.5, state: .cancelled)
        #expect(panel.frame == shrunk && gesture.magnification == 0)
        gesture.emit(0.5, state: .failed)
        #expect(panel.frame == shrunk)
        for invalid in [CGFloat.nan, .infinity, -1, -2] {
            gesture.emit(invalid, state: .began)
            #expect(panel.frame == shrunk && gesture.magnification == 0)
        }
        gesture.emit(0.1, state: .began)
        #expect(abs(panel.frame.width - ((shrunk.width - 24) * 1.1 + 24)) <= 1)
        gesture.emit(0, state: .ended)
    }

    @Test @MainActor
    func deselectionRejectsSystemZoomAndOtherInputsNeverResizeTheImage() throws {
        let panel = makePanel(); defer { panel.close() }
        let surface = try #require(panel.contentView as? CaptureReferenceSurface)
        let installed = try #require(surface.gestureRecognizers.first as? NSMagnificationGestureRecognizer)
        let gesture = SyntheticMagnificationRecognizer(for: surface)
        let original = panel.frame
        gesture.emit(0.2, state: .began)
        #expect(panel.frame == original)
        panel.selectImage()
        // The old responder method and raw-touch callbacks no longer own zoom.
        surface.magnify(with: ImmediateMagnifyEvent(amount: 0.3))
        let touch = NSEvent()
        surface.touchesBegan(with: touch)
        surface.touchesMoved(with: touch)
        surface.touchesEnded(with: touch)
        #expect(panel.frame == original)
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line,
            wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0))
        for flags in [CGEventFlags(), .maskCommand] {
            cg.flags = flags
            surface.scrollWheel(with: try #require(NSEvent(cgEvent: cg)))
            #expect(panel.frame == original)
        }
        gesture.emit(0.2, state: .began)
        let enlarged = panel.frame
        #expect(enlarged.width > original.width)
        panel.deselectImage()
        #expect(installed.isEnabled && installed.magnification == 0)
        #expect(!surface.gestureRecognizerShouldBegin(installed))
        gesture.emit(-0.5, state: .changed)
        #expect(panel.frame == enlarged)
        panel.selectImage()
        #expect(installed.isEnabled)
        gesture.emit(-0.25, state: .began)
        gesture.emit(0, state: .ended)
        #expect(abs(panel.frame.width - ((enlarged.width - 24) * 0.75 + 24)) <= 1)
        panel.contentView = NSView()
        #expect(!installed.isEnabled)
    }

    @Test @MainActor
    func selectingAndDraggingKeepTheInstalledSystemRecognizerAndDeliverMouseUp() throws {
        let panel = makePanel(); defer { panel.close() }
        let surface = try #require(panel.contentView as? CaptureReferenceSurface)
        let installed = try #require(surface.gestureRecognizers.first as? NSMagnificationGestureRecognizer)
        #expect(installed.isEnabled && !surface.mouseDownCanMoveWindow)
        #expect(!panel.isMovableByWindowBackground)
        #expect(!surface.gestureRecognizerShouldBegin(installed))
        let before = panel.frame
        let pointer = CGPoint(x: before.minX + 100, y: before.minY + 70)
        func mouse(_ type: NSEvent.EventType, at screenPoint: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type,
                location: panel.convertPoint(fromScreen: screenPoint), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        }
        let down = try mouse(.leftMouseDown, at: pointer)
        // Gathering occurs before the click selects the image; it must not opt out.
        #expect(surface.gestureRecognizer(installed, shouldAttemptToRecognizeWith: down))
        surface.mouseDown(with: down)
        #expect(panel.isImageSelected && installed.isEnabled)
        #expect(surface.gestureRecognizerShouldBegin(installed))
        let dragged = CGPoint(x: pointer.x + 50, y: pointer.y - 30)
        surface.mouseDragged(with: try mouse(.leftMouseDragged, at: dragged))
        #expect(abs(panel.frame.minX - (before.minX + 50)) <= 1)
        #expect(abs(panel.frame.minY - (before.minY - 30)) <= 1)
        #expect(panel.frame.size == before.size)
        let secondPointer = CGPoint(x: pointer.x + 75, y: pointer.y - 45)
        surface.mouseDragged(with: try mouse(.leftMouseDragged, at: secondPointer))
        #expect(abs(panel.frame.minX - (before.minX + 75)) <= 1)
        #expect(abs(panel.frame.minY - (before.minY - 45)) <= 1)
        surface.mouseUp(with: try mouse(.leftMouseUp, at: secondPointer))
        let released = panel.frame
        surface.mouseDragged(with: try mouse(.leftMouseDragged,
            at: CGPoint(x: dragged.x + 20, y: dragged.y + 20)))
        #expect(panel.frame == released)
        #expect(surface.gestureRecognizers.count == 1 && surface.gestureRecognizers.first === installed)
        let gesture = SyntheticMagnificationRecognizer(for: surface)
        gesture.emit(-0.1, state: .began)
        gesture.emit(0, state: .ended)
        #expect(abs(panel.frame.width - ((released.width - 24) * 0.9 + 24)) <= 1)
    }

    /// Generated coordinates exercise only diagnostic conversion and hit-test
    /// reporting. They do not establish physical trackpad gesture delivery.
    @Test @MainActor
    func inputLocationDistinguishesPhotoGlowAndOutsideWithoutChangingGestureState() throws {
        let panel = makePanel(); defer { panel.close() }
        let surface = try #require(panel.contentView as? CaptureReferenceSurface)
        let installed = try #require(surface.gestureRecognizers.first as? NSMagnificationGestureRecognizer)
        panel.selectImage()
        let original = panel.frame
        let selected = panel.isImageSelected
        let enabled = installed.isEnabled
        let magnification = installed.magnification
        let center = CGPoint(x: surface.bounds.midX, y: surface.bounds.midY)
        let samples: [(CGPoint, Bool)] = [
            (center, true),
            (CGPoint(x: 6, y: center.y), false),
            (CGPoint(x: -8, y: center.y), false)
        ]
        for (point, inPhoto) in samples {
            let eventPoint = surface.convert(point, to: nil)
            let event = try locationEvent(at: eventPoint, in: panel)
            let pointer = panel.convertPoint(toScreen: eventPoint)
            let output = surface.inputLocation(for: event, pointer: pointer)
            let windowPoint = try diagnosticCoordinates("eventWindow", in: output)
            let eventLocal = try diagnosticCoordinates("eventLocal", in: output)
            let pointerLocal = try diagnosticCoordinates("pointerLocal", in: output)
            let edges = try diagnosticCoordinates("edge", in: output)
            try #require(windowPoint.count == 2 && eventLocal.count == 2 && pointerLocal.count == 2 && edges.count == 4)
            #expect(abs(windowPoint[0] - eventPoint.x) < 0.11 && abs(windowPoint[1] - eventPoint.y) < 0.11)
            #expect(abs(eventLocal[0] - point.x) < 0.11 && abs(eventLocal[1] - point.y) < 0.11)
            #expect(abs(pointerLocal[0] - point.x) < 0.11 && abs(pointerLocal[1] - point.y) < 0.11)
            #expect(output.contains("eventInPhoto=\(inPhoto)") && output.contains("pointerInPhoto=\(inPhoto)"))
            #expect(abs(edges[0] - point.x) < 0.11 && abs(edges[1] - point.y) < 0.11)
            #expect(abs(edges[2] - (surface.bounds.width - point.x)) < 0.11)
            #expect(abs(edges[3] - (surface.bounds.height - point.y)) < 0.11)
            let rootHit = try diagnosticToken("rootHit", in: output)
            let frameHit = try diagnosticToken("frameHit", in: output)
            // Window-frame hit testing is AppKit-owned and may differ near
            // a resize edge; retain its reported type without hardcoding it.
            #expect(!frameHit.isEmpty)
            if surface.bounds.contains(point) {
                #expect(rootHit.hasSuffix("CaptureReferenceSurface"))
            } else {
                #expect(rootHit == "nil")
            }
            #expect(panel.frame == original && panel.isImageSelected == selected)
            #expect(surface.gestureRecognizers.count == 1 && surface.gestureRecognizers.first === installed)
            #expect(installed.isEnabled == enabled && installed.magnification == magnification)
        }
        let event = try locationEvent(at: surface.convert(center, to: nil), in: panel)
        let glowPointer = panel.convertPoint(toScreen: surface.convert(CGPoint(x: 6, y: center.y), to: nil))
        let differentPositions = surface.inputLocation(for: event, pointer: glowPointer)
        #expect(differentPositions.contains("eventInPhoto=true"))
        #expect(differentPositions.contains("pointerInPhoto=false"))
        #expect(try diagnosticCoordinates("eventLocal", in: differentPositions)[0] == center.x)
        #expect(try diagnosticCoordinates("pointerLocal", in: differentPositions)[0] == 6)
        #expect(panel.frame == original && panel.isImageSelected == selected)
        #expect(surface.gestureRecognizers.count == 1 && surface.gestureRecognizers.first === installed)
    }

    @Test @MainActor
    func inputLocationKeepsEventAndScreenPointerCoordinatesSeparateAfterWindowMoves() throws {
        let panel = makePanel(); defer { panel.close() }
        let surface = try #require(panel.contentView as? CaptureReferenceSurface)
        let installed = try #require(surface.gestureRecognizers.first as? NSMagnificationGestureRecognizer)
        panel.selectImage()
        let center = CGPoint(x: surface.bounds.midX, y: surface.bounds.midY)
        let fixedPointer = panel.convertPoint(toScreen: surface.convert(center, to: nil))
        let original = panel.frame
        let before = surface.inputLocation(for: try locationEvent(at: surface.convert(center, to: nil), in: panel),
            pointer: fixedPointer)
        #expect(before.contains("eventInPhoto=true") && before.contains("pointerInPhoto=true"))
        panel.setFrameOrigin(CGPoint(x: original.minX + center.x - 6, y: original.minY + 20))
        let moved = panel.frame
        let event = try locationEvent(at: surface.convert(center, to: nil), in: panel)
        let after = surface.inputLocation(for: event, pointer: fixedPointer)
        let eventLocal = try diagnosticCoordinates("eventLocal", in: after)
        let pointerLocal = try diagnosticCoordinates("pointerLocal", in: after)
        try #require(eventLocal.count == 2 && pointerLocal.count == 2)
        #expect(abs(eventLocal[0] - center.x) < 0.11 && abs(eventLocal[1] - center.y) < 0.11)
        #expect(abs(pointerLocal[0] - (center.x - (moved.minX - original.minX))) < 0.11)
        #expect(abs(pointerLocal[1] - (center.y - (moved.minY - original.minY))) < 0.11)
        #expect(after.contains("eventInPhoto=true") && after.contains("pointerInPhoto=false"))
        #expect(panel.frame == moved && panel.isImageSelected)
        #expect(surface.gestureRecognizers.count == 1 && surface.gestureRecognizers.first === installed)
        #expect(installed.isEnabled && installed.magnification == 0)
    }

    @MainActor private func locationEvent(at point: CGPoint, in panel: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
    }

    private func diagnosticCoordinates(_ name: String, in output: String) throws -> [CGFloat] {
        let regex = try NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: name) + "=\\(([^)]*)\\)")
        let match = try #require(regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)))
        let range = try #require(Range(match.range(at: 1), in: output))
        return try output[range].split(separator: ",").map {
            CGFloat(try #require(Double($0.trimmingCharacters(in: .whitespaces))))
        }
    }

    private func diagnosticToken(_ name: String, in output: String) throws -> String {
        let prefix = name + "="
        let start = try #require(output.range(of: prefix)?.upperBound)
        return String(output[start...].prefix { !$0.isWhitespace })
    }

    @MainActor private func makePanel() -> CaptureReferencePanel {
        let panel = CaptureReferencePanel(contentRect: CGRect(x: 100, y: 100, width: 424, height: 224),
            styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.acceptsImageZoom = true
        panel.contentView = CaptureReferenceSurface(image: NSImage(size: CGSize(width: 400, height: 200)),
            frame: CGRect(origin: .zero, size: panel.frame.size))
        return panel
    }

    /// Run separately from other window suites, since this checks the real
    /// shared key window and diagnostic panel across asynchronous flushes.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PASTES_ZOOM_LIVE_LOG_CHECK"] == "1"))
    @MainActor
    func liveLogShowsSystemRecognizerInputWithoutTakingSelectionAndStopsWhenClosed() async throws {
        let screen = try #require(NSScreen.main)
        let panel = CaptureReferencePanel(contentRect: CGRect(x: screen.visibleFrame.minX + 40,
            y: screen.visibleFrame.minY + 40, width: 424, height: 224),
            styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; defer { panel.close() }
        panel.acceptsImageZoom = true
        let surface = CaptureReferenceSurface(image: NSImage(size: CGSize(width: 400, height: 200)),
            frame: CGRect(origin: .zero, size: panel.frame.size))
        panel.contentView = surface
        panel.orderFrontRegardless()
        panel.selectImage()
        // SwiftPM has no NSApplication.run() event loop. Normal image panels
        // need not become key in this host. Check that the logger preserves the
        // actual host focus; real activation/native delivery has a separate
        // physical-device acceptance check in Pastes Dev.
        let previousKey = NSApplication.shared.keyWindow
        #expect(panel.isImageSelected && panel.firstResponder === surface)
        let log = CaptureZoomLiveLog.shared
        log.show(near: panel.frame)
        let logPanel = try #require(NSApplication.shared.windows.first {
            $0 is CaptureZoomLogPanel && $0.isVisible
        } as? CaptureZoomLogPanel)
        defer { logPanel.close() }
        #expect(log.isVisible && !logPanel.canBecomeKey && !logPanel.canBecomeMain)
        #expect(NSApplication.shared.keyWindow === previousKey && panel.isImageSelected)
        let content = try #require(logPanel.contentView)
        let scroll = try #require(content.subviews.compactMap { $0 as? NSScrollView }.first)
        let text = try #require(scroll.documentView as? NSTextView)
        let status = try #require(content.subviews.compactMap { $0 as? NSTextField }.first)
        // A click on the diagnostic window must be exempt from the image's
        // outside-click deselection monitor. Use its empty outer margin.
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let click = try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: 3, y: 3),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: logPanel.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0))
            NSApplication.shared.sendEvent(click)
        }
        #expect(panel.isImageSelected && NSApplication.shared.keyWindow === previousKey)
        // Exercise the actual AppKit mouse dispatch, not only direct responder
        // calls. The whole click must reach this image without server handoff.
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let click = try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: 80, y: 60),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
            NSApplication.shared.sendEvent(click)
        }
        #expect(panel.isImageSelected)
        log.record(.state, window: panel.windowNumber, "SYNTHETIC SYSTEM RECOGNIZER CHECK — generated callback values, not physical trackpad input")
        let gesture = SyntheticMagnificationRecognizer(for: surface)
        gesture.emit(0, state: .began)
        gesture.emit(0.1, state: .changed)
        gesture.emit(-0.05, state: .ended)
        #expect(abs(panel.frame.width - (400 * 1.1 * 0.95 + 24)) <= 1)
        let marker = "live-log-integration-\(UUID())"
        log.record(.state, window: panel.windowNumber, marker)
        var persisted = ""
        for _ in 0..<15 {
            try await Task.sleep(for: .milliseconds(100))
            persisted = (try? String(contentsOf: log.fileURL, encoding: .utf8)) ?? ""
            if persisted.contains(marker), text.string.contains(marker) { break }
        }
        #expect(text.string.contains(marker) && persisted.contains(marker))
        #expect(text.string.contains("image mouseDown; no WindowServer handoff"))
        #expect(text.string.contains("image mouseUp; recognizerEnabled=true"))
        #expect(text.string.contains("onMagnify state=changed delta=0.1") && text.string.contains("zoom=104.5%"))
        #expect(status.stringValue.contains("native 3") && status.stringValue.contains("frame 2"))
        #expect(!text.isEditable && text.font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        #expect(panel.isImageSelected && NSApplication.shared.keyWindow === previousKey)
        if let output = ProcessInfo.processInfo.environment["PASTES_ZOOM_LIVE_LOG_SNAPSHOT_ROOT"],
           CGPreflightScreenCaptureAccess() {
            let windows = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            let own = try #require(windows.windows.first {
                $0.windowID == CGWindowID(logPanel.windowNumber) &&
                $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
            })
            let configuration = SCStreamConfiguration()
            configuration.width = Int(logPanel.frame.width * screen.backingScaleFactor)
            configuration.height = Int(logPanel.frame.height * screen.backingScaleFactor)
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: configuration)
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bitmap = NSBitmapImageRep(cgImage: image)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("live-zoom-log.png"))
        }
        logPanel.close()
        #expect(!log.isVisible && panel.isImageSelected)
        var evaluatedWhileClosed = false
        func closedMessage() -> String {
            evaluatedWhileClosed = true
            return "should not be recorded"
        }
        log.record(.state, closedMessage())
        #expect(!evaluatedWhileClosed)
        log.show(near: panel.frame)
        let resumed = "recording-resumed-\(UUID())"
        log.record(.state, window: panel.windowNumber, resumed)
        for _ in 0..<15 {
            try await Task.sleep(for: .milliseconds(100))
            persisted = (try? String(contentsOf: log.fileURL, encoding: .utf8)) ?? ""
            if persisted.contains(resumed), text.string.contains(resumed) { break }
        }
        #expect(log.isVisible && persisted.contains(resumed) && text.string.contains(resumed))
        #expect(!persisted.contains("should not be recorded"))
    }

    @Test @MainActor
    func defaultRootKeepsImageLayerWithinGlowInsetWithoutAnimations() async throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 40,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try #require(bitmap.bitmapData)
        for y in 0..<40 { for x in 0..<80 {
            let offset = y * bitmap.bytesPerRow + x * 4
            pixels[offset] = 255; pixels[offset + 1] = 0
            pixels[offset + 2] = 0; pixels[offset + 3] = 255
        } }
        let image = NSImage(size: CGSize(width: 80, height: 40))
        image.addRepresentation(bitmap)
        let panel = CaptureReferencePanel(contentRect: CGRect(x: 100, y: 100, width: 424, height: 224),
            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; defer { panel.close() }
        let surface = CaptureReferenceSurface(image: image, frame: CGRect(origin: .zero, size: panel.frame.size))
        panel.contentView = surface
        surface.layoutSubtreeIfNeeded()
        #expect(surface.imageView === surface && panel.contentView === surface)
        #expect(!surface.allowedTouchTypes.contains(.indirect) && !surface.wantsRestingTouches)
        #expect(surface.gestureRecognizers.count == 1 && surface.gestureRecognizers.first is NSMagnificationGestureRecognizer)
        let photo = surface.photoLayer
        #expect(photo.superlayer === surface.layer)
        let contents = try #require(photo.contents)
        #expect(CFGetTypeID(contents as CFTypeRef) == CGImage.typeID)
        let sourceColor = try #require(bitmap.colorAt(x: 40, y: 20)?.usingColorSpace(.deviceRGB))
        #expect(sourceColor.redComponent > 0.9 && sourceColor.alphaComponent > 0.9)
        #expect(photo.frame == surface.bounds.insetBy(dx: 12, dy: 12))
        #expect(photo.contentsGravity == .resizeAspect)
        #expect(photo.contentsScale == panel.backingScaleFactor)
        panel.setFrame(CGRect(x: 100, y: 100, width: 624, height: 324), display: false)
        surface.layoutSubtreeIfNeeded()
        #expect(photo.frame == surface.bounds.insetBy(dx: 12, dy: 12))
        #expect(photo.animationKeys()?.isEmpty != false)
        if let path = ProcessInfo.processInfo.environment["PASTES_CAPTURE_SNAPSHOT_ROOT"] {
            try await Task.sleep(for: .milliseconds(100))
            let rendered = try #require(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
            surface.cacheDisplay(in: surface.bounds, to: rendered)
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try #require(rendered.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("pinned-native-root.png"))
        }
        let context = try #require(CGContext(data: nil, width: Int(surface.bounds.width), height: Int(surface.bounds.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let root = try #require(surface.layer)
        root.render(in: context)
        let layerImage = try #require(context.makeImage())
        let layerBitmap = NSBitmapImageRep(cgImage: layerImage)
        let center = try #require(layerBitmap.colorAt(x: layerImage.width / 2, y: layerImage.height / 2)?.usingColorSpace(.deviceRGB))
        #expect(center.redComponent > 0.9 && center.greenComponent < 0.1 && center.alphaComponent > 0.9)
        if let path = ProcessInfo.processInfo.environment["PASTES_CAPTURE_SNAPSHOT_ROOT"] {
            try #require(layerBitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: path).appendingPathComponent("pinned-native-layer.png"))
        }
    }

    @Test @MainActor
    func displayThumbnailCapsPixelsAndPreservesAspectWithoutUpscaling() throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 600,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let small = try #require(CaptureReferenceImage.make(data: data, maxPixels: 300))
        #expect(small.width == 300 && small.height == 150)
        let full = try #require(CaptureReferenceImage.make(data: data, maxPixels: 2400))
        #expect(full.width == 1200 && full.height == 600)
        #expect(CaptureReferenceImage.make(data: Data("invalid".utf8), maxPixels: 300) == nil)
    }

    @Test @MainActor
    func productionHoldUsesNativeRootAndCopiesOriginalBytes() throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 600,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let editors = CaptureEditors(onSaved: { _ in }, onError: { _ in }, pasteboard: board)
        defer { editors.closeAll() }
        let panel = try editors.hold(data: data, title: "Native root",
            origin: CGRect(x: -10000, y: -10000, width: 400, height: 200))
        let surface = try #require(panel.contentView as? CaptureReferenceSurface)
        #expect(!panel.styleMask.contains(.nonactivatingPanel))
        // borderless has a raw value of zero, so contains(.borderless) cannot
        // establish the intended style. Check the complete mask instead.
        #expect(panel.styleMask == [.borderless, .resizable])
        #expect(panel.level == .floating && !panel.hidesOnDeactivate)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.isVisible && !panel.isImageSelected)
        let installed = try #require(surface.gestureRecognizers.first as? NSMagnificationGestureRecognizer)
        #expect(surface.gestureRecognizers.count == 1)
        #expect(installed.isEnabled && installed.delegate === surface)
        #expect(installed.target === surface && installed.action == #selector(CaptureReferenceDragView.onMagnify(_:)))
        // Exercise the actual hold path without layoutSubtreeIfNeeded().
        #expect(surface.photoLayer.frame == surface.bounds.insetBy(dx: 12, dy: 12))
        #expect(surface.photoLayer.bounds.width > 0 && surface.photoLayer.bounds.height > 0)
        let contents = try #require(surface.photoLayer.contents)
        #expect(CFGetTypeID(contents as CFTypeRef) == CGImage.typeID)
        #expect(surface.imageView === surface)
        #expect(!surface.allowedTouchTypes.contains(.indirect) && !surface.wantsRestingTouches)
        surface.onCopy()
        #expect(board.data(forType: .png) == data)
        let copiedData = try #require(board.data(forType: .png))
        let copied = try #require(NSBitmapImageRep(data: copiedData))
        #expect(copied.pixelsWide == 1200 && copied.pixelsHigh == 600)
    }

    /// Opt-in WindowServer integration check. It only captures this test's own
    /// synthetic photo, never the desktop or an existing application window.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PASTES_CAPTURE_WINDOW_CHECK"] == "1"))
    @MainActor
    func windowServerShowsSyntheticPinnedImageWithoutManualLayout() async throws {
        // Do not request screen-recording access or open a permission prompt.
        guard CGPreflightScreenCaptureAccess() else { return }
        let screen = try #require(NSScreen.main)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 40,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try #require(bitmap.bitmapData)
        for y in 0..<40 { for x in 0..<80 {
            let offset = y * bitmap.bytesPerRow + x * 4
            pixels[offset] = 255; pixels[offset + 1] = 0
            pixels[offset + 2] = 0; pixels[offset + 3] = 255
        } }
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let editors = CaptureEditors(onSaved: { _ in }, onError: { _ in }, pasteboard: board)
        defer { editors.closeAll() }
        let panel = try editors.hold(data: data, title: "Synthetic visibility check",
            origin: CGRect(x: screen.visibleFrame.midX - 120, y: screen.visibleFrame.midY - 60,
                           width: 240, height: 120))
        // Allow actual AppKit/compositor display, without invoking a layout method.
        try await Task.sleep(for: .milliseconds(200))
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let ownWindow = try #require(content.windows.first {
            $0.windowID == CGWindowID(panel.windowNumber) &&
            $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
        })
        let configuration = SCStreamConfiguration()
        configuration.width = Int(panel.frame.width * screen.backingScaleFactor)
        configuration.height = Int(panel.frame.height * screen.backingScaleFactor)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.shouldBeOpaque = false
        configuration.colorSpaceName = CGColorSpace.sRGB
        let capture = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: ownWindow),
            configuration: configuration)
        let rendered = NSBitmapImageRep(cgImage: capture)
        let center = try #require(rendered.colorAt(x: capture.width / 2, y: capture.height / 2)?.usingColorSpace(.deviceRGB))
        // The compositor color-manages the window into the display's gamut.
        // Check the red image's visibility, rather than exact source RGB bytes.
        #expect(center.redComponent > 0.7 && center.redComponent > center.greenComponent + 0.4 &&
                center.redComponent > center.blueComponent + 0.4 && center.alphaComponent > 0.9)
        if let path = ProcessInfo.processInfo.environment["PASTES_CAPTURE_SNAPSHOT_ROOT"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try #require(rendered.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("pinned-windowserver.png"))
        }
        // Synthetic system callback values verify actual window submissions;
        // this does not simulate hardware recognition on a physical trackpad.
        let surface = try #require(panel.contentView as? CaptureReferenceSurface)
        panel.selectImage()
        let original = panel.frame
        let gesture = SyntheticMagnificationRecognizer(for: surface)
        gesture.emit(0.05, state: .began)
        #expect(abs(panel.frame.width - ((original.width - 24) * 1.05 + 24)) <= 1)
        gesture.emit(-0.01, state: .ended)
        #expect(abs(panel.frame.width - ((original.width - 24) * 1.05 * 0.99 + 24)) <= 1)
        try await Task.sleep(for: .milliseconds(150))
        #expect(surface.photoLayer.frame == surface.bounds.insetBy(dx: 12, dy: 12))
        #expect(!surface.zoomBadge.isHidden)
        #expect(surface.zoomBadge.displayedText == "104%")
        if let path = ProcessInfo.processInfo.environment["PASTES_CAPTURE_SNAPSHOT_ROOT"] {
            configuration.width = Int(panel.frame.width * screen.backingScaleFactor)
            configuration.height = Int(panel.frame.height * screen.backingScaleFactor)
            let zoomed = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: ownWindow),
                configuration: configuration)
            let bitmap = NSBitmapImageRep(cgImage: zoomed)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: path).appendingPathComponent("pinned-windowserver-zoom.png"))
        }
        let enlarged = panel.frame
        gesture.emit(-0.25, state: .began)
        // A second system gesture must shrink immediately.
        #expect(abs(panel.frame.width - ((enlarged.width - 24) * 0.75 + 24)) <= 1)
        try await Task.sleep(for: .milliseconds(150))
        #expect(abs(panel.frame.width - ((enlarged.width - 24) * 0.75 + 24)) <= 1)
        #expect(surface.zoomBadge.displayedText == "78%")
        #expect(surface.photoLayer.frame == surface.bounds.insetBy(dx: 12, dy: 12))
        if let path = ProcessInfo.processInfo.environment["PASTES_CAPTURE_SNAPSHOT_ROOT"] {
            configuration.width = Int(panel.frame.width * screen.backingScaleFactor)
            configuration.height = Int(panel.frame.height * screen.backingScaleFactor)
            let shrunk = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: ownWindow),
                configuration: configuration)
            let bitmap = NSBitmapImageRep(cgImage: shrunk)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: path).appendingPathComponent("pinned-windowserver-shrink.png"))
        }
        let final = panel.frame
        panel.finishZoom()
        try await Task.sleep(for: .milliseconds(50))
        #expect(panel.frame == final)

    }

    @Test @MainActor
    func actualPinnedWindowCanGrowPastScreenFitThenShrinkFromFourTimesSize() throws {
        let screen = try #require(NSScreen.main)
        let imageSize = CGSize(width: screen.visibleFrame.height * 0.7 / 3, height: screen.visibleFrame.height * 0.7)
        let panel = CaptureReferencePanel(contentRect: CGRect(x: 100, y: 100,
            width: imageSize.width + 24, height: imageSize.height + 24),
            styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; defer { panel.close() }
        panel.acceptsImageZoom = true
        panel.minSize = CGSize(width: 48, height: 48)
        let reference = panel.frame.insetBy(dx: 12, dy: 12).size
        let surface = CaptureReferenceSurface(image: NSImage(size: reference),
            frame: CGRect(origin: .zero, size: panel.frame.size))
        panel.contentView = surface; panel.selectImage()
        panel.applyMagnification(10)
        #expect(abs(panel.frame.width - (reference.width * 4 + 24)) <= 1)
        #expect(abs(panel.frame.height - (reference.height * 4 + 24)) <= 1)
        #expect(panel.frame.height > screen.visibleFrame.height)
        #expect(surface.zoomBadge.displayedText.contains("400%"))
        panel.finishZoom()
        // Recreating the accumulator for a new gesture retains the original
        // reference and cannot introduce another fourfold expansion.
        surface.zoomBadge.isHidden = true
        panel.applyMagnification(0.3)
        #expect(abs(panel.frame.width - (reference.width * 4 + 24)) <= 1)
        #expect(!surface.zoomBadge.isHidden && surface.zoomBadge.displayedText.contains("400%"))
        let capped = panel.frame
        surface.zoomBadge.isHidden = true
        panel.applyMagnification(0.2)
        #expect(panel.frame == capped && !surface.zoomBadge.isHidden)
        panel.applyMagnification(-0.25)
        #expect(abs(panel.frame.width - (reference.width * 3 + 24)) <= 1)
        #expect(surface.zoomBadge.displayedText == "300%")
    }
}

private final class ImmediateMagnifyEvent: NSEvent {
    let amount: CGFloat
    let eventPhase: NSEvent.Phase
    init(amount: CGFloat, phase: NSEvent.Phase = .changed) {
        self.amount = amount; eventPhase = phase; super.init()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var type: NSEvent.EventType { .magnify }
    override var magnification: CGFloat { amount }
    override var phase: NSEvent.Phase { eventPhase }
}

/// Drives the installed target/action with generated values. It tests callback
/// handling and window updates, not AppKit's recognition of physical input.
final class SyntheticMagnificationRecognizer: NSMagnificationGestureRecognizer {
    private var sampleState: NSGestureRecognizer.State = .possible
    override var state: NSGestureRecognizer.State {
        get { sampleState }
        set { sampleState = newValue }
    }
    init(for view: CaptureReferenceDragView) {
        super.init(target: view, action: view.gestureRecognizers.first?.action)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @discardableResult
    func emit(_ amount: CGFloat, state: NSGestureRecognizer.State = .changed) -> Bool {
        sampleState = state
        magnification = amount
        guard let action else { return false }
        return NSApplication.shared.sendAction(action, to: target, from: self)
    }
}
