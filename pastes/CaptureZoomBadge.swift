import AppKit

/// A point-sized readout owned by the photo surface, outside the photo's scale.
/// Its owner controls visibility and supplies the scale of the displayed frame.
final class CaptureZoomBadge: CALayer {
    enum Limit: Equatable { case minimum, maximum }

    private var label = CATextLayer()
    private struct LayoutInput: Equatable {
        let text: String
        let imageRect: CGRect
        let contentsScale: CGFloat
        let limit: Limit?
    }
    private var previousInput: LayoutInput?
    private static let regularFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    private static let compactFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    var displayedText: String { label.string as? String ?? "" }

    override init() {
        super.init()
        isHidden = true
        backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 0.84).cgColor
        borderColor = NSColor.white.withAlphaComponent(0.48).cgColor
        borderWidth = 0.7
        masksToBounds = true
        cornerCurve = .continuous
        actions = Self.disabledActions
        configureLabel()
        addSublayer(label)
    }

    override init(layer: Any) {
        super.init(layer: layer)
        if let copied = sublayers?.first(where: { $0.name == "zoomPercentage" }) as? CATextLayer {
            label = copied
        } else {
            configureLabel()
            if let source = layer as? CaptureZoomBadge { label.string = source.label.string }
            addSublayer(label)
        }
        actions = Self.disabledActions
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: CGPoint) -> CALayer? { nil }

    func update(scale: CGFloat, imageRect: CGRect, contentsScale: CGFloat, limit: Limit? = nil) {
        // Real window scales are small; also keep malformed diagnostic input
        // from overflowing the percentage conversion.
        let safeScale = scale.isFinite ? min(1_000_000, max(0, scale)) : 1
        let percentage = "\(Int((safeScale * 100).rounded()))%"
        let fullText: String
        switch limit {
        case .minimum: fullText = "\(percentage) · \(C("下限", "Min"))"
        case .maximum: fullText = "\(percentage) · \(C("上限", "Max"))"
        case nil: fullText = percentage
        }
        let pixelScale = contentsScale.isFinite && contentsScale > 0 ? contentsScale : 1
        let input = LayoutInput(text: fullText, imageRect: imageRect, contentsScale: pixelScale, limit: limit)
        guard input != previousInput else { return }
        previousInput = input

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        self.contentsScale = pixelScale
        label.contentsScale = pixelScale
        guard !imageRect.isNull, !imageRect.isInfinite,
              imageRect.width > 0, imageRect.height > 0 else {
            frame = .zero
            label.frame = .zero
            label.string = fullText
            return
        }

        let horizontalInset = min(8, max(0, (imageRect.width - 24) / 2))
        let verticalInset = min(8, max(0, (imageRect.height - 18) / 2))
        let availableWidth = imageRect.width - horizontalInset * 2
        let height = min(24, imageRect.height - verticalInset * 2)
        var text = fullText
        var fontSize = min(12, max(1, height - 6))
        var padding: CGFloat = 10
        var font = Self.font(ofSize: fontSize)
        var textWidth = (text as NSString).size(withAttributes: [.font: font]).width
        if max(56, textWidth + padding * 2) > availableWidth {
            text = percentage
            padding = min(3, availableWidth / 8)
            fontSize = min(11, fontSize)
            font = Self.font(ofSize: fontSize)
            textWidth = (text as NSString).size(withAttributes: [.font: font]).width
        }
        let maximumTextWidth = max(0, availableWidth - padding * 2)
        // Optical sizing means measured glyph widths do not shrink exactly
        // with the requested point size. Verify each candidate, not just the
        // first proportional estimate.
        while textWidth > maximumTextWidth, fontSize > 0.01 {
            fontSize = max(0.01, fontSize * min(0.9, maximumTextWidth / max(1, textWidth)))
            font = Self.font(ofSize: fontSize)
            textWidth = (text as NSString).size(withAttributes: [.font: font]).width
        }
        let width = min(availableWidth, max(min(56, availableWidth), ceil(textWidth + padding * 2)))
        frame = CGRect(x: imageRect.midX - width / 2, y: imageRect.minY + verticalInset,
                       width: width, height: height)
        cornerRadius = height / 2
        label.string = text
        label.font = font
        label.fontSize = fontSize
        let textHeight = min(height, ceil(font.ascender - font.descender))
        label.frame = CGRect(x: padding, y: (height - textHeight) / 2,
                             width: max(0, width - padding * 2), height: textHeight)
    }

    private func configureLabel() {
        label.name = "zoomPercentage"
        label.alignmentMode = .center
        label.isWrapped = false
        label.foregroundColor = NSColor.white.cgColor
        label.actions = Self.disabledActions
    }

    private static func font(ofSize size: CGFloat) -> NSFont {
        if size == 12 { return regularFont }
        if size == 11 { return compactFont }
        return NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
    }

    private static var disabledActions: [String: CAAction] {
        Dictionary(uniqueKeysWithValues: [
            "position", "bounds", "transform", "contents", "contentsScale",
            "backgroundColor", "cornerRadius", "hidden", "opacity",
            "string", "font", "fontSize", "foregroundColor",
            kCAOnOrderIn, kCAOnOrderOut, kCATransition
        ].map { ($0, NSNull()) })
    }
}
