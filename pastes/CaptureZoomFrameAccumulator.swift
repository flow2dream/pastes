import CoreGraphics
import Foundation

/// Coalesces input samples without interpolation or delayed motion. The owner
/// chooses when to commit, and supplies the window's actual frame after rounding.
struct CaptureZoomFrameAccumulator {
    private(set) var baseFrame: CGRect
    private(set) var pendingFrame: CGRect?
    private var lastActualFrame: CGRect
    private let referenceImageSize: CGSize

    init(frame: CGRect, reference: CGSize? = nil) {
        baseFrame = frame
        lastActualFrame = frame
        referenceImageSize = reference ?? frame.insetBy(dx: 12, dy: 12).size
    }

    mutating func enqueue(magnification: CGFloat, actualFrame: CGRect, screen: CGRect,
                          anchor: CGPoint? = nil) {
        guard magnification.isFinite, magnification > -1, magnification != 0 else { return }
        rebaseIfNeeded(actualFrame)
        pendingFrame = CaptureReferenceDragView.scaledFrame(
            pendingFrame ?? baseFrame,
            delta: log1p(magnification),
            screen: screen, reference: referenceImageSize, anchor: anchor)
    }

    /// Applies at most one frame. Returning the actual frame from `apply` keeps
    /// pixel rounding separate from the exact target used by subsequent samples.
    @discardableResult
    mutating func commit(actualFrame: CGRect, apply: (CGRect) -> CGRect) -> Bool {
        rebaseIfNeeded(actualFrame)
        guard let target = pendingFrame else { return false }
        pendingFrame = nil
        // A cap can produce the exact same precise target repeatedly. Preserve
        // subpixel changes; only an exact no-op skips the window submission.
        guard target != baseFrame else { return false }
        lastActualFrame = apply(target)
        // Keep rounding precision, but do not accumulate an unavailable size
        // behind AppKit's constraints: the next reversal starts where shown.
        let constrained = abs(lastActualFrame.width - target.width) > 1
            || abs(lastActualFrame.height - target.height) > 1
        baseFrame = constrained ? lastActualFrame : target
        return true
    }

    /// Natural input completion includes the last sample, with no work left over.
    @discardableResult
    mutating func finish(actualFrame: CGRect, apply: (CGRect) -> CGRect) -> Bool {
        commit(actualFrame: actualFrame, apply: apply)
    }

    /// Dragging, deselection and closure discard targets that were never shown.
    mutating func cancel(actualFrame: CGRect) {
        baseFrame = actualFrame
        lastActualFrame = actualFrame
        pendingFrame = nil
    }

    private mutating func rebaseIfNeeded(_ actualFrame: CGRect) {
        guard actualFrame != lastActualFrame else { return }
        cancel(actualFrame: actualFrame)
    }
}
