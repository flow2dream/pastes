import AppKit
import AVKit
import Combine
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import OSLog

/// Native Markup / AVKit workflow inspired by Tendedero (MIT); see THIRD_PARTY_NOTICES.md.
/// File editors use working copies; pinned references retain edits until closed.
@MainActor
final class CaptureEditors: NSObject, NSWindowDelegate {
    private let onSaved: (URL) async throws -> Void
    private let onError: (Error) -> Void
    private let onReferenceEditingChanged: (Bool) -> Void
    private let pasteboard: NSPasteboard
    private var windows: [NSWindow] = []
    private var movieEditors: [CaptureMovieEditor] = []
    private var imageEditors: [CaptureImageEditor] = []
    private var referenceEditor: NativeScreenshot?
    private weak var referenceEditingWindow: CaptureReferencePanel?

    init(onSaved: @escaping (URL) async throws -> Void, onError: @escaping (Error) -> Void, onReferenceEditingChanged: @escaping (Bool) -> Void = { _ in }, pasteboard: NSPasteboard = .general) {
        self.onSaved = onSaved; self.onError = onError; self.onReferenceEditingChanged = onReferenceEditingChanged
        self.pasteboard = pasteboard
    }
    func hold(_ url: URL, title: String, movie: Bool, origin: CGRect? = nil) {
        guard movie else {
            do { try hold(data: Data(contentsOf: url), title: title, origin: origin) }
            catch { onError(error) }
            return
        }
        let window = CaptureReferencePanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        configureReference(window, title: title)
        let player = AVPlayerView()
        player.player = AVPlayer(url: url); player.controlsStyle = .floating
        window.contentView = player
        windows.append(window); window.center(); window.makeKeyAndOrderFront(nil)
    }
    @discardableResult
    func hold(data: Data, title: String, origin: CGRect? = nil, showImmediately: Bool = true,
              onCloseToShelf: ((Data, CGRect) throws -> Void)? = nil,
              onDestroy: (() throws -> Void)? = nil,
              onClosed: (() -> Void)? = nil) throws -> CaptureReferencePanel {
        guard let image = NSImage(data: data) else { throw CaptureError.invalidMedia }
        let imageFrame = origin ?? CGRect(origin: .zero, size: Self.referenceSize(image: image.size))
        // Keep the original image exactly at the selection, with room outside for its glow.
        // A nonactivating panel can become key without owning native magnify
        // input. Physical A/B testing confirmed that flag suppresses magnify
        // on this system even while AppKit reports key/active. Create a normal
        // panel; activate it only when the user selects the image below.
        let window = CaptureReferencePanel(contentRect: imageFrame.insetBy(dx: -12, dy: -12),
            styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        configureReference(window, title: title)
        window.onCloseToShelf = onCloseToShelf
        window.onDestroy = onDestroy
        window.onClosed = onClosed
        window.onReferenceError = onError
        window.acceptsImageZoom = true
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        // Keep the full mouse sequence in AppKit for gesture recognition.
        // The image view implements dragging without handing off mouse-up.
        window.isMovableByWindowBackground = false
        window.becomesKeyOnlyIfNeeded = false
        window.minSize = NSSize(width: 48, height: 48)
        try updateReference(data: data, in: window)
        windows.append(window)
        if origin == nil { window.center() }
        // Do not activate the app: activation can switch Spaces and cancel an in-flight arrival.
        if showImmediately { window.orderFrontRegardless() }
        return window
    }
    private func configureReference(_ window: CaptureReferencePanel, title: String) {
        window.title = "\(AppEnvironment.displayName) · \(title)"
        window.level = .floating; window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false; window.delegate = self
    }
    func updateReference(data: Data, in window: CaptureReferencePanel) throws {
        guard !window.isReferenceFinished else { throw CaptureError.unavailable }
        // Like Tendedero's held photos, keep only a screen-sized bitmap in the
        // compositor. The closures below retain the original bytes for editing/copy.
        let maxPixels = NSScreen.screens.map {
            max($0.frame.width, $0.frame.height) * $0.backingScaleFactor
        }.max() ?? 4096
        guard let bitmap = CaptureReferenceImage.make(data: data, maxPixels: Int(maxPixels)) else { throw CaptureError.invalidMedia }
        let surface = CaptureReferenceSurface(image: bitmap, frame: CGRect(origin: .zero, size: window.frame.size))
        surface.imageView.onClose = { [weak window] in window?.closeToShelf() }
        surface.imageView.onDestroy = { [weak window] in window?.destroyImage() }
        surface.imageView.onEdit = { [weak self, weak window] in
            guard let self, let window else { return }
            self.editReference(data: data, window: window)
        }
        surface.imageView.onCopy = { [pasteboard] in
            pasteboard.clearContents()
            pasteboard.setData(data, forType: .png)
        }
        window.contentView = surface
        window.referenceData = data
        // A content view created at its final size need not receive a resize or
        // layout pass before the window's first display.
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        window.makeFirstResponder(surface.imageView)
        if AppEnvironment.isDevelopment {
            Logger(subsystem: "com.pastes.capture", category: "pinch").notice("PINNED INPUT activating-panel-v11 window=\(window.windowNumber) nonactivating=\(window.styleMask.contains(.nonactivatingPanel)) bitmap=\(bitmap.width)x\(bitmap.height) photo=\(surface.photoLayer.frame.width)x\(surface.photoLayer.frame.height)")
        }
    }

    private func editReference(data: Data, window: CaptureReferencePanel) {
        guard referenceEditor?.isActive != true else { return }
        let apply: (Data) throws -> Void = { [weak self, weak window] updated in
            guard let self, let window, !window.isReferenceFinished else { throw CaptureError.unavailable }
            try self.updateReference(data: updated, in: window)
        }
        let editor = NativeScreenshot(onActive: { [weak self, weak window] active in
            self?.onReferenceEditingChanged(active)
            if !active { self?.referenceEditingWindow = nil }
            guard let window, !window.isReferenceFinished else { return }
            if active { window.orderOut(nil) } else { window.orderFrontRegardless() }
        }, onCaptured: { [pasteboard] updated, _ in
            try apply(updated)
            pasteboard.clearContents()
            pasteboard.setData(updated, forType: .png)
        }, onError: onError, onPinned: { updated, _ in try apply(updated) },
        onSaved: { updated, _ in try apply(updated) })
        referenceEditor = editor
        referenceEditingWindow = window
        editor.beginEditing(data: data, origin: window.frame.insetBy(dx: 12, dy: 12))
    }
    static func referenceSize(image: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return CGSize(width: 720, height: 480) }
        let scale = min(720 / image.width, 600 / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if referenceEditingWindow === window {
            referenceEditor?.cancel()
            referenceEditor = nil
            referenceEditingWindow = nil
        }
        (window.contentView as? AVPlayerView)?.player?.pause()
        windows.removeAll { $0 === window }
    }
    func edit(_ source: URL, movie: Bool, onOverwrite: ((URL) async throws -> Void)? = nil) {
        if movie {
            let editor = CaptureMovieEditor(url: source, onSaved: onSaved, onError: onError)
            movieEditors.removeAll { $0.window == nil && !$0.isExporting }
            movieEditors.append(editor); editor.show()
            return
        }
        do {
            imageEditors.removeAll { $0.window == nil }
            let editor = try CaptureImageEditor(url: source, onSaved: onSaved, onOverwrite: onOverwrite)
            imageEditors.append(editor)
            editor.show()
        } catch { onError(error) }
    }
    func closeAll() {
        referenceEditor?.cancel(); referenceEditor = nil
        referenceEditingWindow = nil
        for window in Array(windows) { window.close() }
        movieEditors.forEach { $0.cancelAndClose() }; movieEditors = []
        imageEditors.forEach { $0.close() }; imageEditors = []
    }
}

enum CaptureReferenceImage {
    static func make(data: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixels),
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}

final class CaptureReferencePanel: NSPanel {
    var acceptsImageZoom = false
    fileprivate(set) var referenceData: Data?
    fileprivate(set) var isReferenceFinished = false
    fileprivate var onCloseToShelf: ((Data, CGRect) throws -> Void)?
    fileprivate var onDestroy: (() throws -> Void)?
    fileprivate var onClosed: (() -> Void)?
    fileprivate var onReferenceError: ((Error) -> Void)?
    private var finishingReference = false

    /// Explicit close saves before dismissing so a failed import can be retried.
    /// Raw window teardown (including application shutdown) never imports.
    func closeToShelf() {
        guard !isReferenceFinished, !finishingReference else { return }
        finishingReference = true
        defer { finishingReference = false }
        do {
            if let onCloseToShelf {
                guard let referenceData else { throw CaptureError.invalidMedia }
                try onCloseToShelf(referenceData, frame.insetBy(dx: 12, dy: 12))
            }
            close()
        } catch { onReferenceError?(error) }
    }
    func destroyImage() {
        guard !isReferenceFinished, !finishingReference else { return }
        finishingReference = true
        defer { finishingReference = false }
        do {
            try onDestroy?()
            close()
        } catch { onReferenceError?(error) }
    }
    private var referenceImageSize: CGSize?
    var imageZoomStatus: CaptureImageZoomStatus? {
        guard let referenceImageSize else { return nil }
        return CaptureImageZoomStatus(frame: frame, reference: referenceImageSize,
            screen: screen?.visibleFrame ?? frame.insetBy(dx: -1000, dy: -1000))
    }
    private var diagnostics = CaptureZoomDiagnostics()
    override func sendEvent(_ event: NSEvent) {
        let relevant = acceptsImageZoom && [.gesture, .magnify, .beginGesture, .endGesture, .scrollWheel].contains(event.type)
        guard relevant else { super.sendEvent(event); return }
        let started = ProcessInfo.processInfo.systemUptime
        let delay = started - event.timestamp
        if CaptureZoomLiveLog.shared.isRecording, CaptureZoomDiagnostics.shouldTraceLocation(event),
           let surface = contentView as? CaptureReferenceDragView {
            CaptureZoomLiveLog.shared.record(.application, window: windowNumber,
                "window received type=\(CaptureZoomDiagnostics.eventName(event.type)) phase=\(CaptureZoomDiagnostics.phaseName(event.phase)) timestamp=\(event.timestamp) \(surface.inputLocation(for: event, includeWindowLookup: true))")
        }
        // Observe dispatch only. The system recognizer owns its lifecycle and
        // may deliver its action after this event has finished dispatching.
        super.sendEvent(event)
        let dispatched = ProcessInfo.processInfo.systemUptime
        if AppEnvironment.isDevelopment {
            diagnostics.event(event, dispatch: dispatched - started, delay: delay)
            diagnostics.flushIfNeeded(window: windowNumber, force: event.type == .endGesture)
        }
    }
    func recordSystemMagnification() {
        if AppEnvironment.isDevelopment { diagnostics.systemRecognizer() }
    }
    private static weak var selectedPanel: CaptureReferencePanel?
    private(set) var isImageSelected = false
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var zoomFrames: CaptureZoomFrameAccumulator?

    func selectImage() {
        guard acceptsImageZoom else { return }
        if isImageSelected {
            focusImageForSystemGestures()
            return
        }
        if referenceImageSize == nil { referenceImageSize = frame.insetBy(dx: 12, dy: 12).size }
        Self.selectedPanel?.deselectImage()
        Self.selectedPanel = self; isImageSelected = true
        Logger(subsystem: "com.pastes.capture", category: "pinch").notice("SELECTION selected window=\(self.windowNumber)")
        (contentView as? CaptureReferenceSurface)?.imageView.resetPinch()
        (contentView as? CaptureReferenceSurface)?.updateDecoration()
        (contentView as? CaptureReferenceSurface)?.showZoomStatus()
        focusImageForSystemGestures()
        CaptureZoomLiveLog.shared.record(.state, window: windowNumber,
            "selected input=NSMagnificationGestureRecognizer scale=\(imageZoomStatus?.scale ?? 1) key=\(isKeyWindow) appActive=\(NSApp.isActive) frontmostPID=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0) nonactivating=\(styleMask.contains(.nonactivatingPanel)) \((contentView as? CaptureReferenceDragView)?.systemInputStatus ?? "no image view")")
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.window is CaptureZoomLogPanel { return event }
            if event.window !== self { self?.deselectImage() }
            return event
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.deselectImage()
        }
    }
    private func focusImageForSystemGestures() {
        // This runs only for explicit selection/clicks, never hover or arrival.
        // makeKey alone does not guarantee native gesture delivery when another
        // application remains frontmost (as the physical panel A/B showed).
        NSApp.activate(ignoringOtherApps: true)
        makeKey()
        makeFirstResponder((contentView as? CaptureReferenceSurface)?.imageView ?? contentView)
        CaptureZoomLiveLog.shared.record(.state, window: windowNumber,
            "image input focus requested key=\(isKeyWindow) appActive=\(NSApp.isActive) frontmostPID=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0) nonactivating=\(styleMask.contains(.nonactivatingPanel))")
    }
    func deselectImage() {
        if AppEnvironment.isDevelopment { diagnostics.flushIfNeeded(window: windowNumber, force: true) }
        cancelZoom()
        if isImageSelected { CaptureZoomLiveLog.shared.record(.state, window: windowNumber, "selection cleared") }
        if isImageSelected { Logger(subsystem: "com.pastes.capture", category: "pinch").notice("SELECTION cleared window=\(self.windowNumber)") }
        isImageSelected = false
        if Self.selectedPanel === self { Self.selectedPanel = nil }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor); self.localClickMonitor = nil }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor); self.outsideClickMonitor = nil }
        (contentView as? CaptureReferenceSurface)?.imageView.resetPinch()
        (contentView as? CaptureReferenceSurface)?.updateDecoration()
    }
    override func orderOut(_ sender: Any?) { deselectImage(); super.orderOut(sender) }
    override func close() {
        guard !isReferenceFinished else { return }
        isReferenceFinished = true
        deselectImage()
        super.close()
        onClosed?()
        // Release uncommitted screenshot bytes, callbacks and compositor data.
        referenceData = nil
        onCloseToShelf = nil; onDestroy = nil; onClosed = nil; onReferenceError = nil
        contentView = nil
    }
    // Selection is explicit, not keyboard focus: gesture/window transitions may
    // temporarily resign key. Outside clicks already clear selection via monitors.

    func applyMagnification(_ magnification: CGFloat, anchor: CGPoint? = nil) {
        guard enqueueMagnification(magnification, anchor: anchor) else { return }
        commitZoomFrame()
    }
    @discardableResult
    private func enqueueMagnification(_ magnification: CGFloat, anchor: CGPoint?) -> Bool {
        guard acceptsImageZoom, isImageSelected, magnification.isFinite, magnification > -1, magnification != 0 else { return false }
        let available = screen?.visibleFrame ?? frame.insetBy(dx: -1000, dy: -1000)
        if zoomFrames == nil { zoomFrames = CaptureZoomFrameAccumulator(frame: frame, reference: referenceImageSize) }
        zoomFrames?.enqueue(magnification: magnification, actualFrame: frame, screen: available, anchor: anchor)
        return true
    }
    /// Apply the system value immediately, retaining precision across callbacks.
    private func commitZoomFrame() {
        guard var frames = zoomFrames else { return }
        let hadInput = frames.pendingFrame != nil
        let resized = frames.commit(actualFrame: frame) { target in
            self.resizeImage(to: target)
            return self.frame
        }
        zoomFrames = frames
        if hadInput && !resized {
            // Hitting a limit still needs visible feedback.
            (contentView as? CaptureReferenceSurface)?.showZoomStatus()
        }
    }
    private func resizeImage(to target: CGRect) {
        let started = ProcessInfo.processInfo.systemUptime
        let amount = (target.width - 24) / max(1, frame.width - 24) - 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        setFrame(target, display: true)
        CATransaction.commit()
        (contentView as? CaptureReferenceSurface)?.showZoomStatus()
        CaptureZoomLiveLog.shared.record(.frame, window: windowNumber,
            String(format: "zoom=%.1f%% actual=%.2fx%.2f requested=%.2fx%.2f submit=%.3fms",
                (imageZoomStatus?.scale ?? 1) * 100,
                frame.width, frame.height, target.width, target.height,
                (ProcessInfo.processInfo.systemUptime - started) * 1000))
        if AppEnvironment.isDevelopment {
            diagnostics.resize(seconds: ProcessInfo.processInfo.systemUptime - started, amount: amount)
            let scale = imageZoomStatus?.scale ?? 1
            if CaptureZoomDiagnostics.tracesSamples {
                Logger(subsystem: "com.pastes.capture", category: "pinch").debug("ZOOM FRAME requested=\(target.width)x\(target.height) actual=\(self.frame.width)x\(self.frame.height) scale=\(scale) change=\(amount)")
            }
        }
    }
    func finishZoom() {
        commitZoomFrame()
        clearZoom(reason: "finish")
    }
    func cancelZoom() {
        clearZoom(reason: "cancel")
    }
    private func clearZoom(reason: String) {
        if zoomFrames != nil {
            CaptureZoomLiveLog.shared.record(.state, window: windowNumber, "zoom \(reason)")
        }
        zoomFrames = nil
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) {
        if acceptsImageZoom { closeToShelf() } else { close() }
    }
}

struct CaptureImagePreview: View {
    let image: NSImage
    let onClose: () -> Void
    var onEdit: () -> Void = {}
    var onCopy: () -> Void = {}
    var body: some View {
        Image(nsImage: image).resizable().scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { CaptureReferenceDragHandle(onClose: onClose, onEdit: onEdit, onCopy: onCopy) }
            .overlay {
                Rectangle().stroke(Color.blue.opacity(0.85), lineWidth: 1.2)
                    .shadow(color: .blue.opacity(0.65), radius: 5)
                    .allowsHitTesting(false)
            }
            .padding(12)
    }
}

struct CaptureReferenceDragHandle: NSViewRepresentable {
    let onClose: () -> Void
    let onEdit: () -> Void
    let onCopy: () -> Void
    func makeNSView(context: Context) -> CaptureReferenceDragView { CaptureReferenceDragView() }
    func updateNSView(_ view: CaptureReferenceDragView, context: Context) {
        view.onClose = onClose; view.onEdit = onEdit; view.onCopy = onCopy
    }
}

/// The root content view hosts the system magnification recognizer.
/// The photo is a layer rather than an inset child view that can change hit targets.
final class CaptureReferenceSurface: CaptureReferenceDragView {
    var imageView: CaptureReferenceDragView { self }
    init(image: NSImage, frame: CGRect) {
        super.init(frame: frame)
        self.image = image
        updateImageGeometry()
    }
    init(image: CGImage, frame: CGRect) {
        super.init(frame: frame)
        photoLayer.contents = image
        updateImageGeometry()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private let outlineLayer = CAShapeLayer()
    let zoomBadge = CaptureZoomBadge()
    private var zoomBadgeHideTimer: Timer?
    func showZoomStatus() {
        guard let panel = window as? CaptureReferencePanel, panel.isImageSelected,
              let status = panel.imageZoomStatus else { return }
        if zoomBadge.superlayer == nil { layer?.addSublayer(zoomBadge) }
        zoomBadge.update(scale: status.scale, imageRect: bounds.insetBy(dx: 12, dy: 12),
            contentsScale: window?.backingScaleFactor ?? 2, limit: status.limit)
        zoomBadge.isHidden = false
        if let zoomBadgeHideTimer {
            zoomBadgeHideTimer.fireDate = Date(timeIntervalSinceNow: 0.9)
        } else {
            let timer = Timer(timeInterval: 0.9, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.zoomBadge.isHidden = true
                    self?.zoomBadgeHideTimer = nil
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            zoomBadgeHideTimer = timer
        }
    }
    override func layout() {
        super.layout()
        updateImageGeometry()
    }
    private func updateImageGeometry() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        photoLayer.frame = bounds.insetBy(dx: 12, dy: 12)
        photoLayer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
        updateDecoration()
        if zoomBadge.superlayer != nil, let panel = window as? CaptureReferencePanel,
           let status = panel.imageZoomStatus {
            zoomBadge.update(scale: status.scale, imageRect: bounds.insetBy(dx: 12, dy: 12),
                contentsScale: window?.backingScaleFactor ?? 2, limit: status.limit)
        }
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }
    func updateDecoration() {
        if outlineLayer.superlayer == nil {
            outlineLayer.fillColor = nil
            outlineLayer.shadowColor = NSColor.systemBlue.cgColor
            outlineLayer.shadowOffset = .zero
            layer?.addSublayer(outlineLayer)
        }
        let selected = (window as? CaptureReferencePanel)?.isImageSelected == true
        if !selected {
            zoomBadgeHideTimer?.invalidate(); zoomBadgeHideTimer = nil
            zoomBadge.isHidden = true
        }
        let rect = bounds.insetBy(dx: 12, dy: 12)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        outlineLayer.path = CGPath(rect: rect, transform: nil)
        outlineLayer.lineWidth = selected ? 1.25 : 1.1
        outlineLayer.strokeColor = NSColor.systemBlue.withAlphaComponent(selected ? 0.95 : 0.8).cgColor
        outlineLayer.shadowOpacity = selected ? 1 : 0.6
        outlineLayer.shadowRadius = selected ? 5 : 3.5
        outlineLayer.shadowPath = outlineLayer.path?.copy(strokingWithWidth: outlineLayer.lineWidth, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
        CATransaction.commit()
    }

}

class CaptureReferenceDragView: NSView, NSGestureRecognizerDelegate {
    let photoLayer = CALayer()
    var image: NSImage? {
        didSet {
            photoLayer.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
    }
    private var tracking: NSTrackingArea?
    private var lastPointerTrace: TimeInterval = 0
    private var lastTargetLookup: TimeInterval = -.infinity
    private var systemPinch = false
    private var systemPinchAnchor: CGPoint?
    private var dragStart: (pointer: CGPoint, origin: CGPoint)?
    private lazy var magnificationRecognizer: NSMagnificationGestureRecognizer = {
        let recognizer = NSMagnificationGestureRecognizer(target: self, action: #selector(onMagnify(_:)))
        recognizer.delegate = self
        return recognizer
    }()
    func resetPinch() {
        // Install enabled before the first mouse-down, so AppKit can gather
        // this recognizer. Selection gates recognition rather than registration.
        // Only cancel an active gesture; do not restart it on every click.
        if magnificationRecognizer.state == .began || magnificationRecognizer.state == .changed {
            magnificationRecognizer.isEnabled = false
        }
        systemPinch = false
        systemPinchAnchor = nil
        dragStart = nil
        magnificationRecognizer.magnification = 0
        magnificationRecognizer.isEnabled = window != nil
    }
    var systemInputStatus: String {
        "recognizerEnabled=\(magnificationRecognizer.isEnabled) recognizerState=\(CaptureZoomDiagnostics.stateName(magnificationRecognizer.state))"
    }

    /// A passive snapshot. A hit-test is an observation, not AppKit's eventual
    /// gesture recipient. Event and live pointer positions can differ while a
    /// stream remains latched to its original target.
    func inputLocation(for event: NSEvent, pointer: CGPoint? = nil, includeWindowLookup: Bool = false) -> String {
        guard let window else { return "location=no-window" }
        let livePointer = pointer ?? NSEvent.mouseLocation
        let eventScreen = window.convertPoint(toScreen: event.locationInWindow)
        let eventLocal = convert(event.locationInWindow, from: nil)
        let pointerWindow = window.convertPoint(fromScreen: livePointer)
        let pointerLocal = convert(pointerWindow, from: nil)
        func hitName(_ view: NSView) -> String {
            let point = view.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
            return view.hitTest(point).map { NSStringFromClass(type(of: $0)) } ?? "nil"
        }
        let frameHit = superview.map(hitName) ?? "no-frame-view"
        let edge = [eventScreen.x - window.frame.minX, eventScreen.y - window.frame.minY,
                    window.frame.maxX - eventScreen.x, window.frame.maxY - eventScreen.y]
        var result = String(format:
            "eventWindow=(%.1f,%.1f) eventLocal=(%.1f,%.1f) pointerLocal=(%.1f,%.1f) eventScreen=(%.1f,%.1f) pointerScreen=(%.1f,%.1f) eventInPhoto=%@ pointerInPhoto=%@ edge=(%.1f,%.1f,%.1f,%.1f) frame=(%.1f,%.1f,%.1f,%.1f) rootHit=%@ frameHit=%@",
            event.locationInWindow.x, event.locationInWindow.y, eventLocal.x, eventLocal.y,
            pointerLocal.x, pointerLocal.y, eventScreen.x, eventScreen.y, livePointer.x, livePointer.y,
            String(photoLayer.frame.contains(eventLocal)), String(photoLayer.frame.contains(pointerLocal)),
            edge[0], edge[1], edge[2], edge[3], window.frame.minX, window.frame.minY,
            window.frame.width, window.frame.height, hitName(self), frameHit)
        result += " frontmostPID=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0) nonactivating=\(window.styleMask.contains(.nonactivatingPanel))"
        if includeWindowLookup {
            // This public API tests a NEW mouse-down, including transparent
            // pixels/other windows. It cannot reveal an existing gesture latch.
            // Also bound IPC for devices/events that report phase=none.
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastTargetLookup >= 0.15 {
                lastTargetLookup = now
                let target = NSWindow.windowNumber(at: livePointer, belowWindowWithWindowNumber: 0)
                result += " mouseDownTargetNow=\(target) sameWindowNow=\(target == window.windowNumber)"
            } else {
                result += " mouseDownTargetNow=not-sampled"
            }
        }
        return result
    }
    private var selected: Bool { (window as? CaptureReferencePanel)?.isImageSelected == true }
    private let gestureLog = Logger(subsystem: "com.pastes.capture", category: "pinch")
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        // inVisibleRect tracks resizing itself; rebuilding it during a pinch would
        // synthesize repeated enter events and disturb the active gesture target.
        if tracking == nil {
            var options: NSTrackingArea.Options = [.activeAlways, .inVisibleRect, .mouseEnteredAndExited]
            if AppEnvironment.isDevelopment { options.insert(.mouseMoved) }
            let area = NSTrackingArea(rect: .zero, options: options, owner: self)
            addTrackingArea(area); tracking = area
        }
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) {
        // Hover must not steal the selected image's gesture target or activate.
        gestureLog.notice("pointer entered pinned image; key=\(self.window?.isKeyWindow == true), appActive=\(NSApp.isActive)")
        tracePointer(event, action: "entered")
    }
    override func mouseExited(with event: NSEvent) {
        tracePointer(event, action: "exited")
    }
    override func mouseMoved(with event: NSEvent) {
        if event.timestamp - lastPointerTrace >= 0.15 {
            tracePointer(event, action: "moved")
            lastPointerTrace = event.timestamp
        }
        super.mouseMoved(with: event)
    }
    private func tracePointer(_ event: NSEvent, action: String) {
        guard selected, CaptureZoomLiveLog.shared.isRecording else { return }
        CaptureZoomLiveLog.shared.record(.state, window: window?.windowNumber ?? 0,
            "pointer \(action) \(inputLocation(for: event, includeWindowLookup: true))")
    }
    override func scrollWheel(with event: NSEvent) {
        if CaptureZoomLiveLog.shared.isRecording, CaptureZoomDiagnostics.shouldTraceLocation(event) {
            CaptureZoomLiveLog.shared.record(.application, window: window?.windowNumber ?? 0,
                "responder received type=\(CaptureZoomDiagnostics.eventName(event.type)) phase=\(CaptureZoomDiagnostics.phaseName(event.phase)) \(CaptureZoomDiagnostics.eventDetails(event)) \(inputLocation(for: event))")
        }
        // Observation only: scrolling must never become image zoom.
        super.scrollWheel(with: event)
    }
    override func magnify(with event: NSEvent) {
        CaptureZoomLiveLog.shared.record(.application, window: window?.windowNumber ?? 0,
            "responder received type=\(CaptureZoomDiagnostics.eventName(event.type)) phase=\(CaptureZoomDiagnostics.phaseName(event.phase)) \(CaptureZoomDiagnostics.eventDetails(event))")
        // No second zoom path. The installed system recognizer owns scaling.
        super.magnify(with: event)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resetPinch()
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow {
            (window as? CaptureReferencePanel)?.cancelZoom()
            resetPinch()
            magnificationRecognizer.isEnabled = false
        }
        super.viewWillMove(toWindow: newWindow)
    }
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        CaptureZoomLiveLog.shared.record(.application, window: window?.windowNumber ?? 0,
            "system recognizer attempt type=\(CaptureZoomDiagnostics.eventName(event.type)) selected=\(selected) appActive=\(NSApp.isActive) \(systemInputStatus)")
        // The initial click may select the image later in this same dispatch.
        return true
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
        CaptureZoomLiveLog.shared.record(.state, window: window?.windowNumber ?? 0,
            "system recognizer shouldBegin allowed=\(selected) appActive=\(NSApp.isActive) \(systemInputStatus)")
        return selected
    }
    @objc func onMagnify(_ gesture: NSMagnificationGestureRecognizer) {
        guard let panel = window as? CaptureReferencePanel else { return }
        let amount = gesture.magnification
        let state = gesture.state
        // NSMagnificationGestureRecognizer accumulates until its value is
        // reset. Consume each system value exactly once, so the next action
        // contains only new movement, including reversals at a size limit.
        defer { gesture.magnification = 0 }
        panel.recordSystemMagnification()
        CaptureZoomLiveLog.shared.record(.native, window: panel.windowNumber,
            "onMagnify state=\(CaptureZoomDiagnostics.stateName(state)) delta=\(amount) selected=\(selected)")
        guard selected else {
            panel.cancelZoom()
            systemPinch = false; systemPinchAnchor = nil
            CaptureZoomLiveLog.shared.record(.state, window: panel.windowNumber, "system pinch ignored: image not selected")
            return
        }
        switch state {
        case .cancelled, .failed:
            panel.cancelZoom()
            systemPinch = false; systemPinchAnchor = nil
            CaptureZoomLiveLog.shared.record(.state, window: panel.windowNumber, "system pinch \(CaptureZoomDiagnostics.stateName(state))")
            return
        case .began:
            dragStart = nil
            panel.finishZoom()
            systemPinch = false; systemPinchAnchor = nil
        case .changed, .ended:
            break
        default:
            return
        }
        guard amount.isFinite, amount > -1 else {
            CaptureZoomLiveLog.shared.record(.state, window: panel.windowNumber, "system pinch invalid delta ignored")
            if state == .ended {
                panel.finishZoom()
                systemPinch = false; systemPinchAnchor = nil
            }
            return
        }
        if !systemPinch {
            panel.finishZoom()
            systemPinchAnchor = NSEvent.mouseLocation
            systemPinch = true
            CaptureZoomLiveLog.shared.record(.state, window: panel.windowNumber,
                "system pinch began anchor=\(String(describing: systemPinchAnchor))")
        }
        if amount != 0 {
            panel.applyMagnification(amount, anchor: systemPinchAnchor)
        }
        if state == .ended {
            panel.finishZoom()
            systemPinch = false; systemPinchAnchor = nil
            CaptureZoomLiveLog.shared.record(.state, window: panel.windowNumber, "system pinch ended")
        }
    }
    var onClose: () -> Void = {}
    var onDestroy: () -> Void = {}
    var onEdit: () -> Void = {}
    var onCopy: () -> Void = {}
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // The 12pt margin belongs to the image's glow. A material-backed view
        // would paint a solid rectangle behind that margin and the picture.
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false
        photoLayer.contentsGravity = .resizeAspect
        photoLayer.contentsScale = 2
        layer?.addSublayer(photoLayer)
        // System magnification recognition does not request raw NSTouch input.
        addGestureRecognizer(magnificationRecognizer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        (window as? CaptureReferencePanel)?.cancelZoom()
        resetPinch()
        (window as? CaptureReferencePanel)?.selectImage()
        guard let window else { return }
        dragStart = (window.convertPoint(toScreen: event.locationInWindow), window.frame.origin)
        CaptureZoomLiveLog.shared.record(.state, window: window.windowNumber, "image mouseDown; no WindowServer handoff; \(systemInputStatus)")
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragStart else { return }
        let pointer = window.convertPoint(toScreen: event.locationInWindow)
        window.setFrameOrigin(CGPoint(x: dragStart.origin.x + pointer.x - dragStart.pointer.x,
                                      y: dragStart.origin.y + pointer.y - dragStart.pointer.y))
    }
    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        CaptureZoomLiveLog.shared.record(.state, window: window?.windowNumber ?? 0, "image mouseUp; \(systemInputStatus)")
    }
    static func scaledFrame(_ frame: CGRect, delta: CGFloat, screen: CGRect, reference: CGSize? = nil,
                            anchor: CGPoint? = nil) -> CGRect {
        let imageBounds = frame.insetBy(dx: 12, dy: 12)
        guard imageBounds.width > 0, imageBounds.height > 0 else { return frame }
        let natural = reference ?? imageBounds.size
        guard natural.width > 0, natural.height > 0 else { return frame }
        let limits = CaptureImageZoomStatus.range(image: natural, screen: screen)
        let currentScale = min(imageBounds.width / natural.width, imageBounds.height / natural.height)
        let scale = min(limits.upperBound, max(limits.lowerBound, currentScale * exp(min(10, max(-10, delta)))))
        let size = CGSize(width: natural.width * scale + 24, height: natural.height * scale + 24)
        if let anchor, anchor.x.isFinite, anchor.y.isFinite {
            let image = CGRect(x: frame.midX - natural.width * currentScale / 2,
                               y: frame.midY - natural.height * currentScale / 2,
                               width: natural.width * currentScale, height: natural.height * currentScale)
            let point = CGPoint(x: min(image.maxX, max(image.minX, anchor.x)),
                                y: min(image.maxY, max(image.minY, anchor.y)))
            let fraction = CGPoint(x: (point.x - image.minX) / image.width,
                                   y: (point.y - image.minY) / image.height)
            // The glow remains 12pt; keep the actual image pixel under the
            // pointer still, so contractions cannot shrink away from it.
            return CGRect(x: point.x - fraction.x * (size.width - 24) - 12,
                          y: point.y - fraction.y * (size.height - 24) - 12,
                          width: size.width, height: size.height)
        }
        // Programmatic calls without a pointer retain centre-based scaling.
        return CGRect(x: frame.midX - size.width / 2,
                      y: frame.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        (window as? CaptureReferencePanel)?.selectImage()
        let menu = NSMenu()
        for (title, action) in [(C("关闭", "Close"), #selector(closeImage)),
                                (C("销毁", "Destroy"), #selector(destroyImage)),
                                (C("编辑…", "Edit…"), #selector(edit)),
                                (C("复制图片", "Copy image"), #selector(copyImage))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            if action == #selector(closeImage) {
                item.toolTip = C("关闭悬浮图片并挂到图片架", "Close the floating image and add it to the shelf")
            } else if action == #selector(destroyImage) {
                item.toolTip = C("丢弃悬浮图片，不挂到图片架", "Discard the floating image without adding it to the shelf")
            }
            item.target = self; menu.addItem(item)
        }
        return menu
    }
    @objc private func closeImage() { onClose() }
    @objc private func destroyImage() { onDestroy() }
    @objc private func edit() { onEdit() }
    @objc private func copyImage() { onCopy() }
}

@MainActor
private final class CaptureMovieEditor: NSObject, ObservableObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    @Published private(set) var isExporting = false
    private var playerView: AVPlayerView?
    private var ready: AnyCancellable?
    private var exportTask: Task<Void, Never>?
    private let url: URL
    private let onSaved: (URL) async throws -> Void
    private let onError: (Error) -> Void
    init(url: URL, onSaved: @escaping (URL) async throws -> Void, onError: @escaping (Error) -> Void) {
        self.url = url; self.onSaved = onSaved; self.onError = onError
    }
    func show() {
        let item = AVPlayerItem(url: url)
        let view = AVPlayerView()
        view.player = AVPlayer(playerItem: item); view.controlsStyle = .inline
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 500),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "\(AppEnvironment.displayName) · \(C("裁剪录屏（保存副本）", "Trim recording (save a copy)"))"
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isOpaque = false; window.backgroundColor = .clear
        let host = NSHostingView(rootView: CaptureMovieEditorSurface(editor: self, playerView: view, filename: url.lastPathComponent)
            .frame(minWidth: 560, minHeight: 360))
        host.sizingOptions = [.minSize]
        window.contentView = host
        window.contentMinSize = NSSize(width: 560, height: 360)
        window.isReleasedWhenClosed = false; window.delegate = self
        playerView = view
        self.window = window; window.center()
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        ready = item.publisher(for: \.status).filter { $0 != .unknown }.first()
            .receive(on: RunLoop.main).sink { [weak self, weak view] status in
                guard let self, let view else { return }
                guard status == .readyToPlay, view.canBeginTrimming else { onError(CaptureError.invalidTrim); return }
                view.beginTrimming { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if result == .okButton { self.save(item) } else { self.close() }
                    }
                }
            }
    }
    private func save(_ item: AVPlayerItem) {
        guard !isExporting else { return }
        let start = item.reversePlaybackEndTime.isNumeric ? item.reversePlaybackEndTime : .zero
        let end = item.forwardPlaybackEndTime.isNumeric ? item.forwardPlaybackEndTime : item.duration
        guard start >= .zero, end > start else {
            onError(CaptureError.invalidTrim); return
        }
        isExporting = true
        window?.title = C("正在保存裁剪副本…", "Saving trimmed copy…")
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("Trimmed-\(UUID()).mov")
        exportTask = Task {
            defer { isExporting = false; try? FileManager.default.removeItem(at: target) }
            do {
                try await CaptureMovieExport.trim(source: item.asset, range: CMTimeRange(start: start, end: end), destination: target)
                guard !Task.isCancelled else { return }
                try await onSaved(target); close()
            } catch { if !Task.isCancelled { onError(error) } }
        }
    }
    func windowWillClose(_ notification: Notification) {
        playerView?.player?.pause(); playerView = nil
        ready = nil; window = nil
    }
    func close() { window?.close() }
    func cancelAndClose() { exportTask?.cancel(); window?.close() }
    deinit { exportTask?.cancel() }
}

private struct CaptureMovieEditorSurface: View {
    @ObservedObject var editor: CaptureMovieEditor
    let playerView: AVPlayerView
    let filename: String
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                PastesGlassIcon(symbol: "film.stack", tint: .blue, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(C("裁剪录屏", "Trim recording")).font(.system(size: 14, weight: .semibold))
                    Text(filename).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    if editor.isExporting {
                        ProgressView().controlSize(.small)
                        Text(C("正在保存副本…", "Saving copy…"))
                    } else {
                        Label(C("保存副本", "Save a copy"), systemImage: "square.on.square")
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 8).pastesGlass(cornerRadius: 20)
            }.padding(.horizontal, 4)
            CaptureMoviePlayerHost(playerView: playerView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.28), lineWidth: 0.7).allowsHitTesting(false) }
            Text(C("拖动时间范围调整片段，完成后保存为新副本。", "Adjust the time range, then save the trimmed clip as a new copy."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
        }
        .padding(16).padding(.top, 26)
        .background(PastesWindowBackground(cornerRadius: 28))
        .ignoresSafeArea()
    }
}

private struct CaptureMoviePlayerHost: NSViewRepresentable {
    let playerView: AVPlayerView
    func makeNSView(context: Context) -> AVPlayerView { playerView }
    func updateNSView(_ view: AVPlayerView, context: Context) {}
}
