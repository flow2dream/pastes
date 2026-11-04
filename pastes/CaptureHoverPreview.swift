import AppKit
import ImageIO

/// A passive enlargement below the hovered photo. It never activates or consumes clicks.
@MainActor
final class CaptureHoverPreview {
    private var panel: NSPanel?
    private var loading: Task<Void, Never>?
    private var candidate: UUID?
    private var candidateDigest: String?
    private var enteredAt = Date.distantPast
    private var requested = false
    var isVisible: Bool { panel?.isVisible == true }

    func update(item: CaptureItem?, url: URL?, anchor: CGRect?, screen: CGRect?,
                isStillHovering: @escaping () -> Bool) {
        guard isStillHovering(), let item, item.kind == .image, let url, let anchor, let screen else { hide(); return }
        if candidate != item.id || candidateDigest != item.digest {
            hide()
            candidate = item.id
            candidateDigest = item.digest
            enteredAt = Date()
        }
        guard Date().timeIntervalSince(enteredAt) >= 0.45, !requested else { return }
        requested = true
        loading = Task { [weak self] in
            let bitmap = await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil as CGImage? }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1600
                ] as CFDictionary)
            }.value
            guard !Task.isCancelled, let self, self.candidate == item.id, self.candidateDigest == item.digest else { return }
            // Decoding can finish after a menu opens or the pointer leaves.
            // Recheck the real target before ordering any preview window in.
            guard isStillHovering() else { self.hide(); return }
            guard let bitmap,
                  let frame = Self.frame(image: CGSize(width: bitmap.width, height: bitmap.height), anchor: anchor, screen: screen) else { return }
            let preview = self.panel ?? self.makePanel()
            self.panel = preview
            let image = NSImageView(frame: NSRect(origin: .zero, size: frame.size))
            image.image = NSImage(cgImage: bitmap, size: .zero)
            image.imageScaling = .scaleProportionallyUpOrDown
            image.imageAlignment = .alignCenter
            image.wantsLayer = true
            image.layer?.cornerRadius = 10
            image.layer?.masksToBounds = true
            preview.contentView = image
            preview.setFrame(frame, display: true)
            preview.alphaValue = 0
            preview.orderFrontRegardless()
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                preview.animator().alphaValue = 1
            }
        }
    }

    /// AppKit screen coordinates: y grows upwards. Always leave a gap below the card.
    static func frame(image: CGSize, anchor: CGRect, screen: CGRect) -> CGRect? {
        let margin: CGFloat = 16
        let top = min(anchor.minY - 14, screen.maxY - margin)
        let availableHeight = min(460, top - screen.minY - margin)
        let availableWidth = min(680, screen.width - margin * 2)
        guard image.width > 0, image.height > 0, availableHeight > 30, availableWidth > 30 else { return nil }
        let scale = min(availableWidth / image.width, availableHeight / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        let x = min(max(anchor.midX - size.width / 2, screen.minX + margin), screen.maxX - margin - size.width)
        return CGRect(x: x, y: top - size.height, width: size.width, height: size.height)
    }

    private func makePanel() -> NSPanel {
        let result = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        result.isOpaque = false
        result.backgroundColor = .clear
        result.hasShadow = true
        result.level = .floating
        result.hidesOnDeactivate = false
        result.ignoresMouseEvents = true
        CaptureOverlayPolicy.configure(result)
        result.isReleasedWhenClosed = false
        return result
    }

    func hide() {
        loading?.cancel(); loading = nil
        candidate = nil; candidateDigest = nil; requested = false
        panel?.orderOut(nil)
    }
    deinit { loading?.cancel() }
}
