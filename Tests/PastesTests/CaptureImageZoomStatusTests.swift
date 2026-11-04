import AppKit
import Testing
@testable import pastes

@Suite("Pinned-image zoom status", .serialized)
struct CaptureImageZoomStatusTests {
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let reference = CGSize(width: 400, height: 200)

    @Test @MainActor
    func statusUsesDisplayedSizeAndSharesTheResizerBounds() {
        func status(_ width: CGFloat) -> CaptureImageZoomStatus {
            CaptureImageZoomStatus(frame: CGRect(x: 0, y: 0, width: width + 24, height: width / 2 + 24),
                reference: reference, screen: screen)
        }
        #expect(status(400).scale == 1 && status(400).limit == nil)
        #expect(status(320).scale == 0.8 && status(320).limit == nil)
        #expect(status(600).scale == 1.5)
        #expect(abs(status(400).minimum - 0.12) < 0.000001)
        #expect(status(400).maximum == 4)
        #expect(status(1600).limit == .maximum)
        #expect(status(48).limit == .minimum)
    }

    @Test @MainActor
    func aWindowDimensionConstraintReportsTheImageScaleThatActuallyFits() {
        let frame = CGRect(x: 0, y: 0, width: 824, height: 224)
        let status = CaptureImageZoomStatus(frame: frame, reference: reference, screen: screen)
        // The 2:1 image fits the constrained height at 1x, despite a 2x-wide
        // window. The next contraction must begin at the displayed image size.
        #expect(status.scale == 1 && status.limit == nil)
        let contracted = CaptureReferenceDragView.scaledFrame(frame, delta: log(0.9), screen: screen,
            reference: reference)
        #expect(abs(contracted.width - 384) < 0.000001)
        #expect(abs(contracted.height - 204) < 0.000001)
        let updated = CaptureImageZoomStatus(frame: contracted, reference: reference, screen: screen)
        #expect(abs(updated.scale - 0.9) < 0.000001)
    }

    @Test @MainActor
    func scaleRangeIsIndependentOfScreenFitAndKeepsValidMinimums() {
        let expected: ClosedRange<CGFloat> = 0.12...4
        for screenSize in [CGSize(width: 100, height: 80), CGSize(width: 1000, height: 800),
                           CGSize(width: 8000, height: 5000)] {
            let available = CGRect(origin: .zero, size: screenSize)
            #expect(CaptureImageZoomStatus.range(image: reference, screen: available) == expected)
        }
        let large = CaptureImageZoomStatus.range(image: CGSize(width: 4000, height: 2000), screen: screen)
        #expect(large == 0.1...4)
        let narrow = CaptureImageZoomStatus.range(image: CGSize(width: 1000, height: 30), screen: screen)
        #expect(narrow == 0.8...4)
        let tiny = CaptureImageZoomStatus.range(image: CGSize(width: 2, height: 4), screen: screen)
        #expect(tiny == 4...4)
        let empty = CaptureImageZoomStatus.range(image: .zero, screen: .zero)
        #expect(empty == 4...4)
    }

    @Test @MainActor
    func shrinkingFromMaximumRespondsImmediatelyWithoutAccumulatedOvershoot() {
        let initial = CGRect(x: 100, y: 100, width: 424, height: 224)
        var frames = CaptureZoomFrameAccumulator(frame: initial)
        var actual = initial
        for _ in 0..<10 {
            frames.enqueue(magnification: 0.8, actualFrame: actual, screen: screen)
            frames.commit(actualFrame: actual) { actual = $0; return actual }
        }
        #expect(actual.width == reference.width * 4 + 24)
        #expect(actual.width > screen.width)
        let before = CaptureImageZoomStatus(frame: actual, reference: reference, screen: screen)
        #expect(before.limit == .maximum && before.scale == 4)
        let beforeWidth = actual.width
        frames.enqueue(magnification: -0.2, actualFrame: actual, screen: screen)
        frames.commit(actualFrame: actual) { actual = $0; return actual }
        let after = CaptureImageZoomStatus(frame: actual, reference: reference, screen: screen)
        #expect(after.limit == nil)
        #expect(abs(after.scale - before.scale * 0.8) < 0.000001)
        #expect(actual.width < beforeWidth - 150)
    }
}

// These integration checks share the app's one selected pinned window, so keep
// them in the same serialized suite as the WindowServer/system-gesture checks.
extension CaptureImmediateZoomTests {
    @Test @MainActor
    func badgeTracksActualWindowIncludingShrinkAndDisappearsAfterInput() async throws {
        let panel = CaptureReferencePanel(contentRect: CGRect(x: 100, y: 100, width: 424, height: 224),
            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; defer { panel.close() }
        panel.acceptsImageZoom = true
        let surface = CaptureReferenceSurface(image: NSImage(size: CGSize(width: 400, height: 200)),
            frame: CGRect(origin: .zero, size: panel.frame.size))
        panel.contentView = surface; panel.selectImage()
        #expect(surface.zoomBadge.displayedText == "100%")
        let gesture = SyntheticMagnificationRecognizer(for: surface)
        gesture.emit(-0.2, state: .began)
        // The first input and its displayed percentage are immediate.
        #expect(surface.zoomBadge.displayedText == "80%")
        #expect(surface.zoomBadge.displayedText == "80%")
        #expect(!surface.zoomBadge.isHidden)
        #expect(abs((panel.imageZoomStatus?.scale ?? 0) - 0.8) < 0.005)
        panel.finishZoom()
        try await Task.sleep(for: .milliseconds(1000))
        #expect(surface.zoomBadge.isHidden)
        let shown = panel.frame
        panel.selectImage(); surface.showZoomStatus()
        #expect(!surface.zoomBadge.isHidden)
        panel.deselectImage()
        #expect(surface.zoomBadge.isHidden && panel.frame == shown)
    }
}
