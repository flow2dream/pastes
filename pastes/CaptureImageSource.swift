import AppKit
import ApplicationServices

/// Reads image elements exposed by the source application. Never substitutes the
/// cursor or a whole window for image bounds, and never requests extra permission.
@MainActor
final class CaptureImageSource {
    private var eventMonitor: Any?
    private var pending: (pid: pid_t, rect: CGRect, date: Date)?

    func start() {
        stop()
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.type == .rightMouseDown {
                    self.pending = nil
                    if let app = NSWorkspace.shared.frontmostApplication,
                       let rect = self.imageAtPointer(pid: app.processIdentifier) {
                        self.pending = (app.processIdentifier, rect, Date())
                    }
                } else if event.type == .keyDown {
                    let isCopy = event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers?.lowercased() == "c"
                    self.pending = nil
                    if isCopy, let app = NSWorkspace.shared.frontmostApplication,
                       let rect = self.focusedImage(pid: app.processIdentifier) {
                        self.pending = (app.processIdentifier, rect, Date())
                    }
                } else if self.pending.map({ Date().timeIntervalSince($0.date) > 8 }) == true {
                    self.pending = nil
                }
            }
        }
    }
    func stop() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil; pending = nil
    }
    deinit { if let eventMonitor { NSEvent.removeMonitor(eventMonitor) } }

    func consume(imageSize: CGSize) -> CGRect? {
        defer { pending = nil }
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return nil }
        if let pending, pending.pid == app.processIdentifier,
           Date().timeIntervalSince(pending.date) < 8,
           Self.matchesImage(pending.rect, imageSize: imageSize) { return pending.rect }
        guard let rect = focusedImage(pid: app.processIdentifier),
              Self.matchesImage(rect, imageSize: imageSize) else { return nil }
        return rect
    }
    nonisolated static func matchesImage(_ rect: CGRect, imageSize: CGSize) -> Bool {
        guard rect.width >= 16, rect.height >= 16, imageSize.width > 0, imageSize.height > 0 else { return false }
        let ratio = (rect.width / rect.height) / (imageSize.width / imageSize.height)
        return abs(log(ratio)) < 0.12
    }
    nonisolated static func appKitRect(position: CGPoint, size: CGSize, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: position.x, y: primaryHeight - position.y - size.height, width: size.width, height: size.height)
    }
    private func appElement(_ pid: pid_t) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        return app
    }
    private func imageAtPointer(pid: pid_t) -> CGRect? {
        guard let app = appElement(pid), let primary = NSScreen.screens.first else { return nil }
        let point = NSEvent.mouseLocation
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(primary.frame.height - point.y), &hit) == .success,
              let hit else { return nil }
        return imageAncestor(hit)
    }
    private func focusedImage(pid: pid_t) -> CGRect? {
        guard let app = appElement(pid), let focused = element(app, kAXFocusedUIElementAttribute) else { return nil }
        if let rect = imageAncestor(focused) { return rect }
        // Only a unique selected image is a defensible source for keyboard Copy.
        if let selected = attribute(focused, kAXSelectedChildrenAttribute) as? [AXUIElement], selected.count == 1 {
            return imageAncestor(selected[0])
        }
        return nil
    }
    private func imageAncestor(_ start: AXUIElement) -> CGRect? {
        var current: AXUIElement? = start
        for _ in 0..<6 {
            guard let node = current else { break }
            if attribute(node, kAXRoleAttribute) as? String == kAXImageRole {
                guard let p = attribute(node, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
                      let s = attribute(node, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
                var point = CGPoint.zero; var size = CGSize.zero
                guard AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &point),
                      AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size),
                      let primary = NSScreen.screens.first else { return nil }
                let rect = Self.appKitRect(position: point, size: size, primaryHeight: primary.frame.height)
                return NSScreen.screens.contains(where: { $0.frame.intersects(rect) }) ? rect : nil
            }
            current = element(node, kAXParentAttribute)
        }
        return nil
    }
    private func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func element(_ node: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(node, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
}
