import AppKit
import SwiftUI
import Carbon.HIToolbox
import OSLog

private final class ShelfWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel {
            // Start at the newest (rightmost) images. Scrolling down reveals older images.
            let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : -event.scrollingDeltaY
            NotificationCenter.default.post(name: .captureShelfScroll, object: delta)
        } else { super.sendEvent(event) }
    }
}

@MainActor
final class CaptureShelfPanel {
    struct ArrivalRequest {
        let arrival: CaptureLibrary.Arrival
        let contextEpoch: Int
    }
    private let controller: CaptureController
    private let panel: ShelfWindow
    let shortcut = HotkeyManager(prefix: "captureShortcut", keyCode: kVK_ANSI_T,
        modifiers: controlKey | optionKey | (AppEnvironment.isDevelopment ? shiftKey : 0), signature: 0x505343)
    private var timer: Timer?
    private let hoverPreview = CaptureHoverPreview()
    private let flightAnimator = CaptureFlightAnimator()
    private var awaySince: Date?
    private var displayedScreenFrame: CGRect?
    private var shownAt = Date.distantPast
    private var arrivalVisibleUntil = Date.distantPast
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var applicationObservers: [NSObjectProtocol] = []
    private var menuObservers: [NSObjectProtocol] = []
    private var trackedMenus: Set<ObjectIdentifier> = []
    private var screenshotActive = false
    private var pendingArrival: ArrivalRequest?
    private var revealTask: Task<Void, Never>?
    private var contextEpoch = 0
    private struct ReferenceFlight {
        let reference: CaptureReferencePanel
        let task: Task<Void, Never>
        let closeObserver: NSObjectProtocol
    }
    private var referenceFlights: [UUID: ReferenceFlight] = [:]
    var isDragging = false
    var hoveredItem: UUID?
    var hitRects: [UUID: CGRect] = [:]
    var controlRects: [CGRect] = []
    private var hideGeneration = 0
    var menuOpen = false {
        didSet { if menuOpen { hoverPreview.hide(); hoveredItem = nil } }
    }
    var allowsHoverPreview: Bool {
        !screenshotActive && !isDragging && !menuOpen && trackedMenus.isEmpty && referenceFlights.isEmpty
    }

    init(controller: CaptureController) {
        self.controller = controller
        panel = ShelfWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 240),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = false; panel.hidesOnDeactivate = false
        CaptureOverlayPolicy.configure(panel)
        panel.isFloatingPanel = true; panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(rootView: CaptureShelfView(controller: controller, library: controller.library))
        // The common-mode polling timer also runs while a status/context menu
        // tracks. A menu can cover a photo without changing its geometry.
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
            menuObservers.append(NotificationCenter.default.addObserver(forName: name,
                object: nil, queue: .main) { [weak self] notification in
                guard let menu = notification.object as? NSMenu else { return }
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSMenu.didBeginTrackingNotification {
                        self.trackedMenus.insert(ObjectIdentifier(menu))
                        self.hoverPreview.hide()
                        self.hoveredItem = nil
                    } else {
                        self.trackedMenus.remove(ObjectIdentifier(menu))
                    }
                }
            })
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.hideForContextChange(reason: "display configuration changed") } }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.hideForContextChange(reason: "active Space changed") } }
        let workspace = NSWorkspace.shared.notificationCenter
        applicationObservers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                // The old app also deactivates when we gain focus. That event
                // must not cancel our screenshot's pending arrival. Only another
                // app becoming active proves that the user left this context.
                MainActor.assumeIsolated {
                    self?.hideForContextChange(reason: "external app activated pid=\(app.processIdentifier) front=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1)")
                }
            })
    }
    func setEnabled(_ enabled: Bool) {
        timer?.invalidate(); timer = nil
        shortcut.unregister()
        if enabled {
            if !shortcut.register(onTrigger: { [weak self] in self?.toggle() }) {
                controller.errorMessage = shortcut.registrationError
            }
            let pollingTimer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
            RunLoop.main.add(pollingTimer, forMode: .common)
            timer = pollingTimer
        } else { hide() }
    }
    private var isPresentedOnCurrentSpace: Bool {
        panel.isVisible && panel.isOnActiveSpace && !NSApp.isHidden
    }
    func toggle() { isPresentedOnCurrentSpace && controller.lineRevealed ? hide() : show() }
    func arrivalRequest(for arrival: CaptureLibrary.Arrival) -> ArrivalRequest {
        ArrivalRequest(arrival: arrival, contextEpoch: contextEpoch)
    }
    func showForArrival(_ request: ArrivalRequest) {
        guard request.contextEpoch == contextEpoch else { return }
        pendingArrival = request
        showPendingArrival()
    }
    private func showPendingArrival() {
        guard let request = pendingArrival else { return }
        guard controller.enabled, request.contextEpoch == contextEpoch,
              controller.library.arrivalTokens[request.arrival.itemID] == request.arrival.token,
              controller.library.visibleItems.contains(where: { $0.id == request.arrival.itemID }) else {
            pendingArrival = nil
            return
        }
        // Confirmation imports before NativeScreenshot finishes. Reentrant UI
        // work can deliver this event while the overlay is still active.
        guard !screenshotActive else {
            traceArrival("waiting for screenshot to finish")
            return
        }
        let origin = controller.library.arrivalOrigins[request.arrival.itemID]
        show(at: origin.map { CGPoint(x: $0.midX, y: $0.midY) })
    }
    func setScreenshotActive(_ active: Bool) {
        screenshotActive = active
        if active {
            contextEpoch += 1
            pendingArrival = nil
            revealTask?.cancel(); revealTask = nil
            cancelReferenceFlights()
            flightAnimator.cancelAll(); hoverPreview.hide()
            hideGeneration += 1
            panel.orderOut(nil)
            var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
            withTransaction(transaction) { controller.lineRevealed = false }
        }
        if !active { showPendingArrival() }
    }
    func show(at origin: CGPoint? = nil) {
        let location = origin ?? NSEvent.mouseLocation
        guard controller.enabled, !screenshotActive,
              let screen = NSScreen.screens.first(where: { Self.isAtTopEdge(location, screen: $0.frame) || $0.frame.contains(location) }) ?? NSScreen.main else { return }
        revealTask?.cancel()
        hideGeneration += 1
        displayedScreenFrame = screen.frame
        let width = screen.visibleFrame.width
        controller.updateShelfWidth(width)
        panel.setFrame(NSRect(x: screen.visibleFrame.midX - width / 2,
                              y: screen.visibleFrame.maxY - CaptureLineLayout.height, width: width, height: CaptureLineLayout.height), display: true)
        if !isPresentedOnCurrentSpace { controller.lineRevealed = false }
        controller.onShelfWillShow?()
        NSApp.unhideWithoutActivation()
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        let generation = hideGeneration
        revealTask = Task { [weak self] in
            // WindowServer can take several turns to migrate moveToActiveSpace
            // panels after a fullscreen swipe. Keep the row tucked until ready.
            await Task.yield()
            for _ in 0..<60 {
                guard !Task.isCancelled, let self, self.hideGeneration == generation,
                      self.controller.enabled, !self.screenshotActive else { return }
                if self.isPresentedOnCurrentSpace {
                    self.controller.lineRevealed = true
                    if self.pendingArrival != nil {
                        self.pendingArrival = nil
                        self.arrivalVisibleUntil = Date().addingTimeInterval(3.5)
                    }
                    self.revealTask = nil
                    self.traceArrival("shelf ready on current Space")
                    return
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
            guard let self, self.hideGeneration == generation else { return }
            self.revealTask = nil
            self.controller.lineRevealed = false
            self.panel.orderOut(nil)
            self.pendingArrival = nil
            self.traceArrival("current Space presentation timed out")
        }
        shownAt = Date(); awaySince = nil
    }
    func hide() {
        contextEpoch += 1
        pendingArrival = nil
        revealTask?.cancel(); revealTask = nil
        cancelReferenceFlights()
        flightAnimator.cancelAll()
        hoverPreview.hide()
        hideGeneration += 1
        let generation = hideGeneration
        controller.lineRevealed = false
        awaySince = nil; hoveredItem = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
            guard let self, self.hideGeneration == generation else { return }
            self.panel.orderOut(nil)
        }
    }
    private func hideForContextChange(reason: String = "shelf left active Space") {
        // Dragging into another app must keep its source and session alive.
        guard !isDragging else { return }
        contextEpoch += 1
        pendingArrival = nil
        revealTask?.cancel(); revealTask = nil
        cancelReferenceFlights()
        traceArrival("\(reason); previous arrival cancelled")
        hideGeneration += 1
        flightAnimator.cancelAll()
        hoverPreview.hide()
        panel.orderOut(nil)
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { controller.lineRevealed = false }
        awaySince = nil; hoveredItem = nil
    }
    private func tick() {
        updateHover(at: NSEvent.mouseLocation, now: Date())
    }
    func updateHover(at pointer: CGPoint, now: Date) {
        guard !screenshotActive else { return }
        guard allowsHoverPreview else { hoverPreview.hide(); return }
        // During a swipe, the old panel can remain logically visible while its Space
        // has already stopped being active. Dismiss it unless it is still migrating in.
        if panel.isVisible && !panel.isOnActiveSpace {
            // This is an order-in still waiting for migration, not an old shelf
            // left visible after a context switch. Real notifications cancel it.
            if revealTask != nil { return }
            hideForContextChange()
            return
        }
        if isPresentedOnCurrentSpace {
            let local = CGPoint(x: pointer.x - panel.frame.minX, y: panel.frame.maxY - pointer.y)
            let visibleIDs = Set(controller.library.visibleItems.map(\.id))
            let photos = hitRects.filter { visibleIDs.contains($0.key) }.map(\.value)
            let region = CaptureShelfInteractionRegion(bounds: CGRect(origin: .zero, size: panel.frame.size),
                photoRects: photos, controlRects: controlRects,
                topCorridorMinY: panel.frame.maxY - (displayedScreenFrame?.maxY ?? panel.frame.maxY))
            // When the row overflows, its gaps and navigation controls must receive
            // wheel/trackpad events too, otherwise they fall through to the app below.
            let needsScrolling = CaptureLineLayout.overflow(itemCount: controller.library.visibleItems.count, width: panel.frame.width) > 0
            panel.ignoresMouseEvents = !region.receivesMouse(at: local, scrolling: needsScrolling)
            // Restore mouse handling before querying the frontmost hit window:
            // the previous tick may have made the panel transparent in a gap.
            if let target = hoverTarget(at: pointer), let screen = panel.screen {
                hoverPreview.update(item: target.item, url: controller.library.url(for: target.item),
                    anchor: target.anchor, screen: screen.visibleFrame,
                    isStillHovering: { [weak self] in
                        guard let current = self?.hoverTarget(at: NSEvent.mouseLocation) else { return false }
                        return current.item.id == target.item.id && current.item.digest == target.item.digest
                            && current.anchor == target.anchor
                    })
            } else { hoverPreview.hide() }
            // Keep the menu-bar corridor open so the user can rest at the top edge
            // or move down to a photo without triggering an automatic tuck.
            if region.keepsOpen(at: local) || displayedScreenFrame.map({ Self.isAtTopEdge(pointer, screen: $0) }) == true {
                awaySince = nil
            } else if now.timeIntervalSince(shownAt) > 1 && now > arrivalVisibleUntil {
                if awaySince == nil { awaySince = now }
                if now.timeIntervalSince(awaySince!) > 0.65 { hide() }
            }
            return
        }
        hoverPreview.hide()
        // Hover only manages an already presented shelf. Opening it requires an
        // explicit action (shortcut/button) or a newly confirmed image arrival.
    }
    private func hoverTarget(at pointer: CGPoint) -> (item: CaptureItem, anchor: CGRect)? {
        guard allowsHoverPreview, isPresentedOnCurrentSpace, controller.lineRevealed,
              panel.frame.contains(pointer) else { return nil }
        let local = CGPoint(x: pointer.x - panel.frame.minX, y: panel.frame.maxY - pointer.y)
        guard let hit = hitRects.first(where: { $0.value.contains(local) }),
              let item = controller.library.visibleItems.first(where: { $0.id == hit.key && $0.kind == .image }),
              NSWindow.windowNumber(at: pointer, belowWindowWithWindowNumber: 0) == panel.windowNumber else { return nil }
        return (item, CGRect(x: panel.frame.minX + hit.value.minX, y: panel.frame.maxY - hit.value.maxY,
                             width: hit.value.width, height: hit.value.height))
    }
    func screenRect(for id: UUID) -> CGRect? {
        guard isPresentedOnCurrentSpace, let rect = hitRects[id] else { return nil }
        return CGRect(x: panel.frame.minX + rect.minX, y: panel.frame.maxY - rect.maxY,
                      width: rect.width, height: rect.height)
    }
    func presentReference(_ reference: CaptureReferencePanel, image: NSImage, from source: CGRect,
                          onFinished: @escaping () -> Void) {
        guard !reference.isReferenceFinished else { onFinished(); return }
        guard isPresentedOnCurrentSpace, controller.lineRevealed, source.intersects(panel.frame) else {
            reference.orderFrontRegardless()
            onFinished()
            return
        }
        hoverPreview.hide()
        let token = UUID()
        let destination = reference.frame.insetBy(dx: 12, dy: 12)
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
            object: reference, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.referenceFlights[token]?.task.cancel()
                self?.flightAnimator.cancel(token)
            }
        }
        let task = Task { [self, reference] in
            defer {
                if let flight = referenceFlights.removeValue(forKey: token) {
                    NotificationCenter.default.removeObserver(flight.closeObserver)
                }
                // Cancellation still finishes the user's Float action. A
                // reference explicitly closed meanwhile must never reappear.
                if !reference.isReferenceFinished { reference.orderFrontRegardless() }
                onFinished()
            }
            do {
                try await flightAnimator.fly(image: image, origin: source, target: destination,
                    token: token, duration: 0.42, initialHold: .zero, arrivalHold: .zero) {
                    if !reference.isReferenceFinished { reference.orderFrontRegardless() }
                }
            } catch { /* Restore the reference in the cleanup above. */ }
        }
        referenceFlights[token] = ReferenceFlight(reference: reference, task: task, closeObserver: observer)
    }
    private func cancelReferenceFlights() {
        for (token, flight) in referenceFlights {
            flight.task.cancel()
            flightAnimator.cancel(token)
            if !flight.reference.isReferenceFinished { flight.reference.orderFrontRegardless() }
        }
    }
    func flyImage(_ image: NSImage, itemID: UUID, token: UUID, onArrival: () -> Void) async throws {
        let generation = hideGeneration
        var destination: CGRect?
        // A newly ordered-in NSHostingView can publish its card geometry after
        // the reveal task starts. Wait for that layout instead of consuming an
        // arrival that has never flown. Context changes still cancel immediately.
        for _ in 0..<50 {
            try Task.checkCancellation()
            guard hideGeneration == generation, isPresentedOnCurrentSpace, controller.lineRevealed,
                  controller.library.arrivalTokens[itemID] == token else { throw CancellationError() }
            if let target = screenRect(for: itemID), target.intersects(panel.frame) {
                destination = target
                break
            }
            try await Task.sleep(for: .milliseconds(16))
        }
        guard let target = destination else { throw CancellationError() }
        guard let origin = controller.library.arrivalOrigins[itemID] else { return }
        hoverPreview.hide()
        let flightImage: NSImage
        if let item = controller.library.visibleItems.first(where: { $0.id == itemID }), item.kind == .image {
            flightImage = NSImage(contentsOf: controller.library.url(for: item)) ?? image
        } else { flightImage = image }
        try await flightAnimator.fly(image: flightImage, origin: origin, target: target.insetBy(dx: 4, dy: 4), token: token, onArrival: onArrival)
    }

    static func isAtTopEdge(_ point: CGPoint, screen: CGRect) -> Bool {
        point.x >= screen.minX && point.x < screen.maxX && point.y >= screen.maxY - 5 && point.y <= screen.maxY
    }

    private func traceArrival(_ message: String) {
        guard AppEnvironment.isDevelopment else { return }
        Logger(subsystem: "com.pastes.capture", category: "arrival")
            .notice("\(message, privacy: .public) epoch=\(self.contextEpoch) screenshotActive=\(self.screenshotActive) visible=\(self.panel.isVisible) activeSpace=\(self.panel.isOnActiveSpace) revealed=\(self.controller.lineRevealed)")
    }

    func stop() { hoverPreview.hide(); setEnabled(false) }
    deinit {
        timer?.invalidate()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        for observer in applicationObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in menuObservers { NotificationCenter.default.removeObserver(observer) }
    }
}
