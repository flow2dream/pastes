import CoreGraphics

/// Percentages use the first pinned image size as 100%, excluding its glow.
/// Bounds are shared by the resize path and the on-image status display.
struct CaptureImageZoomStatus {
    let scale: CGFloat
    let minimum: CGFloat
    let maximum: CGFloat
    let limit: CaptureZoomBadge.Limit?

    init(frame: CGRect, reference: CGSize, screen: CGRect) {
        let image = frame.insetBy(dx: 12, dy: 12)
        let range = Self.range(image: reference, screen: screen)
        minimum = range.lowerBound; maximum = range.upperBound
        // The image layer uses resizeAspect. If AppKit constrains just one
        // window dimension, the shorter fitted dimension is the visible scale.
        scale = min(image.width / max(1, reference.width), image.height / max(1, reference.height))
        // Window frames can round to backing pixels at either bound.
        let tolerance = max(1 / max(1, reference.width), 1 / max(1, reference.height))
        if scale <= minimum + tolerance { limit = .minimum }
        else if scale >= maximum - tolerance { limit = .maximum }
        else { limit = nil }
    }

    static func range(image: CGSize, screen: CGRect) -> ClosedRange<CGFloat> {
        let width = max(1, image.width), height = max(1, image.height)
        let minimum = max(0.1, 24 / width, 24 / height)
        let maximum: CGFloat = 4
        // The scale range follows the original pinned size, even if a larger
        // photo extends beyond the screen. Tiny references still need a valid range.
        return min(minimum, maximum)...maximum
    }
}
