import AppKit

/// Global screen coordinates throughout; no fixed “drop from above” origin.
struct CaptureFlightPath {
    let start: CGRect
    let target: CGRect

    init(origin: CGRect, target: CGRect) {
        self.target = target
        start = origin
    }

    func frame(at progress: Double) -> CGRect {
        let t = min(1, max(0, progress))
        // Smooth acceleration and braking, with no overshoot at the clip.
        let eased = CGFloat(t * t * t * (t * (t * 6 - 15) + 10))
        let distance = hypot(target.midX - start.midX, target.midY - start.midY)
        let arc = sin(.pi * eased) * min(36, distance * 0.06)
        let width = start.width + (target.width - start.width) * eased
        let height = start.height + (target.height - start.height) * eased
        let x = start.midX + (target.midX - start.midX) * eased
        let y = start.midY + (target.midY - start.midY) * eased + arc
        return CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
    }
}

@MainActor
final class CaptureFlightAnimator {
    private var windows: [UUID: NSPanel] = [:]

    func fly(image: NSImage, origin: CGRect, target: CGRect, token: UUID,
             duration: Double = 0.55, initialHold: Duration = .milliseconds(80),
             arrivalHold: Duration = .milliseconds(180), onArrival: () -> Void) async throws {
        try Task.checkCancellation()
        let path = CaptureFlightPath(origin: origin, target: target)
        // Copying a card already on the shelf only needs a small settle, not a loop.
        guard hypot(path.start.midX - target.midX, path.start.midY - target.midY) > 24 else { onArrival(); return }
        let panel = NSPanel(contentRect: path.start, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1); panel.isReleasedWhenClosed = false
        CaptureOverlayPolicy.configure(panel)
        let view = NSImageView(frame: CGRect(origin: .zero, size: path.start.size))
        view.image = image; view.imageScaling = .scaleProportionallyUpOrDown
        view.wantsLayer = true; view.layer?.cornerRadius = 8; view.layer?.masksToBounds = true
        view.layer?.borderWidth = 1.5
        view.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        panel.contentView = view
        windows[token]?.orderOut(nil)
        windows[token] = panel
        defer {
            panel.orderOut(nil)
            if windows[token] === panel { windows.removeValue(forKey: token) }
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        try await Task.sleep(for: initialHold)
        let began = ContinuousClock.now
        while windows[token] === panel {
            try Task.checkCancellation()
            let elapsed = began.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let progress = min(1, seconds / max(0.001, duration))
            panel.setFrame(path.frame(at: progress), display: true)
            panel.alphaValue = 1
            if progress >= 1 {
                onArrival()
                // Hold the flying image until the shelf card has faded in underneath it.
                try await Task.sleep(for: arrivalHold)
                return
            }
            try await Task.sleep(for: .milliseconds(16))
        }
        throw CancellationError()
    }

    func cancelAll() {
        for panel in windows.values { panel.orderOut(nil) }
        windows.removeAll()
    }
    func cancel(_ token: UUID) {
        windows.removeValue(forKey: token)?.orderOut(nil)
    }
}
