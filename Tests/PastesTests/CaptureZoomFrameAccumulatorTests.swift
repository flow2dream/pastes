import CoreGraphics
import Foundation
import Testing
@testable import pastes

@Suite("Pinned-image frame coalescing")
struct CaptureZoomFrameAccumulatorTests {
    private let initial = CGRect(x: 200, y: 200, width: 424, height: 224)
    private let screen = CGRect(x: 0, y: 0, width: 2400, height: 1600)

    @Test @MainActor
    func burstCommitsOnceAndMicroReversalsKeepAllPendingScale() throws {
        var accumulator = CaptureZoomFrameAccumulator(frame: initial)
        let amounts: [CGFloat] = [0.1, 0.02, -0.0001, 0.03, -0.05, 0.01]
        var scale: CGFloat = 1
        for amount in amounts {
            accumulator.enqueue(magnification: amount, actualFrame: initial, screen: screen)
            scale *= 1 + amount
        }
        let expectedWidth = 400 * scale + 24
        let pending = try #require(accumulator.pendingFrame)
        #expect(abs(pending.width - expectedWidth) < 0.00001)
        #expect(accumulator.baseFrame == initial)
        var submissions = 0
        var actual = initial
        #expect(accumulator.commit(actualFrame: actual) { target in
            submissions += 1
            actual = rounded(target)
            return actual
        })
        #expect(submissions == 1)
        #expect(accumulator.pendingFrame == nil)
        #expect(abs(accumulator.baseFrame.width - expectedWidth) < 0.00001)
        #expect(!accumulator.commit(actualFrame: actual) { _ in
            submissions += 1
            return actual
        })
        #expect(submissions == 1)
    }

    @Test @MainActor
    func tinySamplesSurviveWindowRoundingAcrossManyCommits() {
        var accumulator = CaptureZoomFrameAccumulator(frame: initial)
        var actual = initial
        for _ in 0..<100 {
            accumulator.enqueue(magnification: -0.0005, actualFrame: actual, screen: screen)
            accumulator.commit(actualFrame: actual) { target in
                actual = rounded(target)
                return actual
            }
        }
        #expect(abs(accumulator.baseFrame.width - (400 * pow(0.9995, 100) + 24)) < 0.00001)
        #expect(actual.width < initial.width - 15)
    }

    @Test @MainActor
    func externalMoveDiscardsAnOldTargetBeforeTheNextCommit() {
        var accumulator = CaptureZoomFrameAccumulator(frame: initial)
        accumulator.enqueue(magnification: 0.2, actualFrame: initial, screen: screen)
        let moved = initial.offsetBy(dx: 80, dy: 35)
        var submissions = 0
        #expect(!accumulator.commit(actualFrame: moved) { target in
            submissions += 1
            return target
        })
        #expect(submissions == 0 && accumulator.pendingFrame == nil)
        #expect(accumulator.baseFrame == moved)
        accumulator.enqueue(magnification: -0.1, actualFrame: moved, screen: screen)
        #expect(abs((accumulator.pendingFrame?.width ?? 0) - 384) < 0.00001)
        #expect(accumulator.pendingFrame?.midX == moved.midX)
    }

    @Test @MainActor
    func externalResizeRebasesNewInputInsteadOfUsingAnUnshownTarget() throws {
        var accumulator = CaptureZoomFrameAccumulator(frame: initial)
        accumulator.enqueue(magnification: 0.3, actualFrame: initial, screen: screen)
        let resized = CGRect(x: 200, y: 200, width: 624, height: 324)
        accumulator.enqueue(magnification: -0.1, actualFrame: resized, screen: screen)
        let target = try #require(accumulator.pendingFrame)
        #expect(abs(target.width - 564) < 0.00001)
        #expect(abs(target.height - 294) < 0.00001)
        #expect(target.midX == resized.midX && target.midY == resized.midY)
    }

    @Test @MainActor
    func naturalFinishFlushesOnceWhileCancellationNeverAppliesPendingMovement() {
        var accumulator = CaptureZoomFrameAccumulator(frame: initial)
        accumulator.enqueue(magnification: 0.2, actualFrame: initial, screen: screen)
        var actual = initial
        var submissions = 0
        #expect(accumulator.finish(actualFrame: actual) { target in
            submissions += 1
            actual = rounded(target)
            return actual
        })
        #expect(submissions == 1 && accumulator.pendingFrame == nil)
        #expect(abs(accumulator.baseFrame.width - 504) < 0.00001)
        accumulator.enqueue(magnification: -0.1, actualFrame: actual, screen: screen)
        accumulator.cancel(actualFrame: actual)
        #expect(accumulator.baseFrame == actual && accumulator.pendingFrame == nil)
        #expect(!accumulator.finish(actualFrame: actual) { _ in
            submissions += 1
            return actual
        })
        #expect(submissions == 1)
    }

    @Test @MainActor
    func invalidAndZeroSamplesLeaveThePendingTargetUntouched() {
        var accumulator = CaptureZoomFrameAccumulator(frame: initial)
        accumulator.enqueue(magnification: 0.1, actualFrame: initial, screen: screen)
        let target = accumulator.pendingFrame
        for amount in [CGFloat.zero, .nan, .infinity, -.infinity, -1, -2] {
            accumulator.enqueue(magnification: amount, actualFrame: initial, screen: screen)
            #expect(accumulator.pendingFrame == target)
        }
    }

    @Test @MainActor
    func largeNativeContractionUsesItsEntireValidFactorBeforeTheImageLimit() throws {
        let enlarged = CGRect(x: 100, y: 100, width: 1624, height: 824)
        var accumulator = CaptureZoomFrameAccumulator(frame: enlarged, reference: CGSize(width: 400, height: 200))
        accumulator.enqueue(magnification: -0.95, actualFrame: enlarged, screen: screen)
        let target = try #require(accumulator.pendingFrame)
        // 400% × (1 - 0.95) is 20%, above the image's 12% minimum.
        // Clamping each event's factor to 0.1 incorrectly leaves it at 40%.
        #expect(abs(target.width - 104) < 0.000001)
        #expect(abs(target.height - 64) < 0.000001)
    }

    @Test @MainActor
    func repeatedExpansionStaysAtFourTimesReferenceAndExactCapCommitsAreNoops() throws {
        var accumulator = CaptureZoomFrameAccumulator(frame: initial)
        var actual = initial
        for _ in 0..<12 {
            accumulator.enqueue(magnification: 1, actualFrame: actual, screen: screen)
        }
        let target = try #require(accumulator.pendingFrame)
        #expect(target.width == 1624 && target.height == 824)
        var submissions = 0
        #expect(accumulator.commit(actualFrame: actual) { target in
            submissions += 1
            actual = target
            return actual
        })
        #expect(submissions == 1)
        for _ in 0..<12 {
            accumulator.enqueue(magnification: 1, actualFrame: actual, screen: screen)
            #expect(!accumulator.commit(actualFrame: actual) { target in
                submissions += 1
                actual = target
                return actual
            })
        }
        #expect(submissions == 1 && accumulator.pendingFrame == nil)
        accumulator.enqueue(magnification: -0.1, actualFrame: actual, screen: screen)
        #expect(accumulator.commit(actualFrame: actual) { target in
            submissions += 1
            actual = target
            return actual
        })
        #expect(submissions == 2)
        #expect(abs(actual.width - 1464) < 0.000001)
    }

    @Test @MainActor
    func suppliedReferenceKeepsOriginalLimitsAfterRecreatingAccumulatorAtLargerSize() throws {
        let reference = CGSize(width: 400, height: 200)
        let enlarged = CGRect(x: 100, y: 100, width: 824, height: 424)
        let smallScreen = CGRect(x: 0, y: 0, width: 600, height: 400)
        var accumulator = CaptureZoomFrameAccumulator(frame: enlarged, reference: reference)
        accumulator.enqueue(magnification: 10, actualFrame: enlarged, screen: smallScreen)
        let target = try #require(accumulator.pendingFrame)
        #expect(target.width == 1624 && target.height == 824)
        #expect(target.width > smallScreen.width && target.height > smallScreen.height)
        var actual = enlarged
        accumulator.commit(actualFrame: actual) { actual = $0; return actual }
        accumulator.cancel(actualFrame: actual)
        accumulator.enqueue(magnification: -0.5, actualFrame: actual, screen: smallScreen)
        let reduced = try #require(accumulator.pendingFrame)
        #expect(reduced.width == 824 && reduced.height == 424)
        #expect(accumulator.baseFrame.size == target.size)
    }

    @Test @MainActor
    func subpixelTargetStillCommitsEvenWhenActualWindowRoundsToItsOldFrame() {
        var accumulator = CaptureZoomFrameAccumulator(frame: initial)
        accumulator.enqueue(magnification: -0.00001, actualFrame: initial, screen: screen)
        var submissions = 0
        #expect(accumulator.commit(actualFrame: initial) { _ in
            submissions += 1
            return initial
        })
        #expect(submissions == 1)
        #expect(accumulator.baseFrame.width < initial.width)
        accumulator.enqueue(magnification: -0.00001, actualFrame: initial, screen: screen)
        #expect(accumulator.commit(actualFrame: initial) { _ in
            submissions += 1
            return initial
        })
        #expect(submissions == 2)
        #expect(abs(accumulator.baseFrame.width - (400 * pow(0.99999, 2) + 24)) < 0.000001)
    }

    @Test @MainActor
    func appliedSizeConstraintRebasesBeforeTheFirstContraction() throws {
        func constrained(_ target: CGRect) -> CGRect {
            let width = min(target.width, 624), height = min(target.height, 324)
            return CGRect(x: target.midX - width / 2, y: target.midY - height / 2,
                          width: width, height: height)
        }
        var accumulator = CaptureZoomFrameAccumulator(frame: initial)
        var actual = initial
        accumulator.enqueue(magnification: 3, actualFrame: actual, screen: screen)
        #expect(accumulator.commit(actualFrame: actual) { target in
            actual = constrained(target)
            return actual
        })
        #expect(actual.width == 624 && actual.height == 324)
        #expect(accumulator.baseFrame == actual)
        let limited = actual

        accumulator.enqueue(magnification: -0.01, actualFrame: actual, screen: screen)
        let next = try #require(accumulator.pendingFrame)
        #expect(abs(next.width - (600 * 0.99 + 24)) < 0.000001)
        #expect(abs(next.height - (300 * 0.99 + 24)) < 0.000001)
        #expect(accumulator.commit(actualFrame: actual) { target in
            actual = constrained(target)
            return actual
        })
        #expect(actual.width < limited.width && actual.height < limited.height)
        #expect(actual == next && accumulator.pendingFrame == nil)
    }

    @Test @MainActor
    func heightOnlyConstraintContractsImmediatelyAndRestoresTheReferenceAspect() throws {
        func constrainedHeight(_ target: CGRect) -> CGRect {
            let height = min(target.height, 324)
            return CGRect(x: target.minX, y: target.midY - height / 2,
                          width: target.width, height: height)
        }
        var accumulator = CaptureZoomFrameAccumulator(frame: initial)
        var actual = initial
        accumulator.enqueue(magnification: 3, actualFrame: actual, screen: screen)
        #expect(accumulator.commit(actualFrame: actual) { target in
            actual = constrainedHeight(target)
            return actual
        })
        #expect(actual.width == 1624 && actual.height == 324)
        #expect(accumulator.baseFrame == actual)
        let limited = actual

        accumulator.enqueue(magnification: -0.01, actualFrame: actual, screen: screen)
        let next = try #require(accumulator.pendingFrame)
        // The displayed aspect-fit photo is 600×300 inside the constrained
        // frame, so its first contraction uses that scale, not the frame width.
        #expect(abs(next.width - (600 * 0.99 + 24)) < 0.000001)
        #expect(abs(next.height - (300 * 0.99 + 24)) < 0.000001)
        #expect(accumulator.commit(actualFrame: actual) { target in
            actual = constrainedHeight(target)
            return actual
        })
        #expect(actual.width < limited.width && actual.height < limited.height)
        #expect(abs((actual.width - 24) / (actual.height - 24) - 2) < 0.000001)
        #expect(actual == next && accumulator.pendingFrame == nil)
    }

    @Test @MainActor
    func pointerAnchorUsesTheVisibleAspectFitImageAfterAHeightConstraint() throws {
        let reference = CGSize(width: 400, height: 200)
        let constrained = CGRect(x: 200, y: 200, width: 1624, height: 324)
        let visible = CGRect(x: constrained.midX - 300, y: constrained.midY - 150,
                             width: 600, height: 300)
        let normalized = CGPoint(x: 0.9, y: 0.75)
        let anchor = CGPoint(x: visible.minX + visible.width * normalized.x,
                             y: visible.minY + visible.height * normalized.y)
        var accumulator = CaptureZoomFrameAccumulator(frame: constrained, reference: reference)
        accumulator.enqueue(magnification: -0.1, actualFrame: constrained, screen: screen, anchor: anchor)
        let target = try #require(accumulator.pendingFrame)
        #expect(abs(target.width - 564) < 0.000001)
        #expect(abs(target.height - 294) < 0.000001)
        expectImagePoint(anchor, in: target, normalized: normalized)
    }

    @Test @MainActor
    func onePointSizeRoundingStillPreservesThePreciseTarget() throws {
        var accumulator = CaptureZoomFrameAccumulator(frame: initial)
        var actual = initial
        accumulator.enqueue(magnification: 0.1, actualFrame: actual, screen: screen)
        let target = try #require(accumulator.pendingFrame)
        #expect(accumulator.commit(actualFrame: actual) { requested in
            actual = CGRect(origin: requested.origin,
                            size: CGSize(width: requested.width + 1, height: requested.height - 1))
            return actual
        })
        #expect(accumulator.baseFrame == target)
        #expect(accumulator.baseFrame != actual)
        accumulator.enqueue(magnification: -0.0001, actualFrame: actual, screen: screen)
        let next = try #require(accumulator.pendingFrame)
        #expect(abs(next.width - ((target.width - 24) * 0.9999 + 24)) < 0.000001)
        #expect(abs(next.height - ((target.height - 24) * 0.9999 + 24)) < 0.000001)
    }

    @Test @MainActor
    func pointerAnchorKeepsTheSameImagePixelAcrossBurstsAndWindowRounding() throws {
        let normalized = CGPoint(x: 0.9, y: 0.9)
        let anchor = imagePoint(in: initial, normalized: normalized)
        var accumulator = CaptureZoomFrameAccumulator(frame: initial)
        var actual = initial
        var scale: CGFloat = 1
        let bursts: [[CGFloat]] = [
            [0.2, -0.1, 0.03, -0.0001],
            [-0.25, 0.15, -0.002, 0.04]
        ]
        for burst in bursts {
            for amount in burst {
                accumulator.enqueue(magnification: amount, actualFrame: actual, screen: screen, anchor: anchor)
                scale *= 1 + amount
                let pending = try #require(accumulator.pendingFrame)
                expectImagePoint(anchor, in: pending, normalized: normalized)
                #expect(abs(pending.width - (400 * scale + 24)) < 0.000001)
            }
            #expect(accumulator.commit(actualFrame: actual) { target in
                actual = rounded(target)
                return actual
            })
            // The precise target retains the same pixel, while the displayed
            // window can place it within one point due to frame rounding.
            expectImagePoint(anchor, in: accumulator.baseFrame, normalized: normalized)
            expectImagePoint(anchor, in: actual, normalized: normalized, tolerance: 1)
        }
        #expect(accumulator.pendingFrame == nil)
        #expect(abs(accumulator.baseFrame.width - (400 * scale + 24)) < 0.000001)
    }

    @Test @MainActor
    func pointerAnchorSurvivesTheMaximumThenRespondsToTheFirstContraction() throws {
        let normalized = CGPoint(x: 0.9, y: 0.9)
        let anchor = imagePoint(in: initial, normalized: normalized)
        var accumulator = CaptureZoomFrameAccumulator(frame: initial)
        var actual = initial
        for _ in 0..<12 {
            accumulator.enqueue(magnification: 1, actualFrame: actual, screen: screen, anchor: anchor)
        }
        let capped = try #require(accumulator.pendingFrame)
        #expect(capped.width == 1624 && capped.height == 824)
        expectImagePoint(anchor, in: capped, normalized: normalized)
        #expect(accumulator.commit(actualFrame: actual) { actual = $0; return actual })

        accumulator.enqueue(magnification: -0.25, actualFrame: actual, screen: screen, anchor: anchor)
        let contracted = try #require(accumulator.pendingFrame)
        #expect(contracted.width == 1224 && contracted.height == 624)
        expectImagePoint(anchor, in: contracted, normalized: normalized)
        #expect(accumulator.commit(actualFrame: actual) { actual = $0; return actual })
        #expect(actual.width < capped.width && actual.height < capped.height)
        expectImagePoint(anchor, in: actual, normalized: normalized)
    }

    @Test @MainActor
    func pointerAnchorOnANegativeOriginScreenDoesNotClampTheFrameToItsBounds() throws {
        let secondary = CGRect(x: -1440, y: -900, width: 1440, height: 900)
        let original = CGRect(x: -1100, y: -800, width: 424, height: 224)
        let normalized = CGPoint(x: 0.9, y: 0.9)
        let anchor = imagePoint(in: original, normalized: normalized)
        var accumulator = CaptureZoomFrameAccumulator(frame: original)
        accumulator.enqueue(magnification: 3, actualFrame: original, screen: secondary, anchor: anchor)
        let pending = try #require(accumulator.pendingFrame)
        #expect(pending.width == 1624 && pending.height == 824)
        #expect(pending.minX < secondary.minX && pending.minY < secondary.minY)
        expectImagePoint(anchor, in: pending, normalized: normalized)
    }

    @Test @MainActor
    func omittingThePointerAnchorRetainsTheImageCenterDuringAReversingBurst() throws {
        var accumulator = CaptureZoomFrameAccumulator(frame: initial)
        var scale: CGFloat = 1
        for amount: CGFloat in [0.2, -0.15, 0.03, -0.04] {
            accumulator.enqueue(magnification: amount, actualFrame: initial, screen: screen)
            scale *= 1 + amount
            let pending = try #require(accumulator.pendingFrame)
            #expect(abs(pending.midX - initial.midX) < 0.000001)
            #expect(abs(pending.midY - initial.midY) < 0.000001)
        }
        #expect(abs((accumulator.pendingFrame?.width ?? 0) - (400 * scale + 24)) < 0.000001)
    }

    private func imagePoint(in frame: CGRect, normalized: CGPoint) -> CGPoint {
        let image = frame.insetBy(dx: 12, dy: 12)
        return CGPoint(x: image.minX + image.width * normalized.x,
                       y: image.minY + image.height * normalized.y)
    }

    private func expectImagePoint(_ expected: CGPoint, in frame: CGRect, normalized: CGPoint,
                                  tolerance: CGFloat = 0.000001) {
        let point = imagePoint(in: frame, normalized: normalized)
        #expect(abs(point.x - expected.x) <= tolerance)
        #expect(abs(point.y - expected.y) <= tolerance)
    }

    private func rounded(_ frame: CGRect) -> CGRect {
        CGRect(x: frame.minX.rounded(), y: frame.minY.rounded(),
               width: frame.width.rounded(), height: frame.height.rounded())
    }
}
