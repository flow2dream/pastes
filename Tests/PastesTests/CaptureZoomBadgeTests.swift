import AppKit
import Testing
@testable import pastes

@Suite("Pinned-image zoom readout")
struct CaptureZoomBadgeTests {
    @Test @MainActor
    func percentageUsesDisplayedScaleAndOwnerControlsVisibility() {
        let badge = CaptureZoomBadge()
        let image = CGRect(x: 12, y: 12, width: 400, height: 200)
        #expect(badge.isHidden)
        let samples: [(CGFloat, String)] = [(1, "100%"), (0.85, "85%"), (1.4, "140%")]
        for (scale, text) in samples {
            badge.update(scale: scale, imageRect: image, contentsScale: 2)
            #expect(badge.displayedText == text)
            #expect(badge.isHidden)
        }
        badge.isHidden = false
        badge.update(scale: 1, imageRect: image, contentsScale: 2, limit: .minimum)
        #expect(badge.displayedText == "100% · \(C("下限", "Min"))")
        badge.update(scale: 1.4, imageRect: image, contentsScale: 2, limit: .maximum)
        #expect(badge.displayedText == "140% · \(C("上限", "Max"))")
        #expect(!badge.isHidden)
    }

    @Test @MainActor
    func pointSizeStaysConstantAndReadoutTracksImageBottomCenter() throws {
        let badge = CaptureZoomBadge()
        let image = CGRect(x: 20, y: 30, width: 400, height: 200)
        badge.update(scale: 1, imageRect: image, contentsScale: 1)
        let originalSize = badge.bounds.size
        #expect(badge.frame.midX == image.midX)
        #expect(badge.frame.minY == image.minY + 8)
        #expect(image.contains(badge.frame))
        let largerImage = CGRect(x: -50, y: 70, width: 800, height: 400)
        badge.update(scale: 2, imageRect: largerImage, contentsScale: 2)
        #expect(badge.bounds.size == originalSize)
        #expect(badge.frame.midX == largerImage.midX)
        #expect(badge.frame.minY == largerImage.minY + 8)
        #expect(badge.contentsScale == 2)
        let text = try #require(badge.sublayers?.first as? CATextLayer)
        #expect(text.contentsScale == 2 && text.fontSize == 12)
        #expect(CATransform3DIsIdentity(badge.transform))
    }

    @Test @MainActor
    func narrowImageKeepsCompactPercentageWithinPhoto() throws {
        let badge = CaptureZoomBadge()
        let image = CGRect(x: 12, y: 12, width: 24, height: 100)
        badge.update(scale: 1, imageRect: image, contentsScale: 2, limit: .maximum)
        #expect(badge.displayedText == "100%")
        #expect(image.contains(badge.frame))
        #expect(badge.frame.midX == image.midX)
        let text = try #require(badge.sublayers?.first as? CATextLayer)
        #expect(badge.bounds.contains(text.frame))
        let font = try #require(text.font as? NSFont)
        let neededWidth = (badge.displayedText as NSString).size(withAttributes: [.font: font]).width
        #expect(neededWidth <= text.bounds.width + 0.01)
        #expect(text.fontSize < 12)
    }

    @Test @MainActor
    func repeatedLayoutPreservesOwnerVisibilityAndChangedInputsStillRefresh() throws {
        let badge = CaptureZoomBadge()
        let image = CGRect(x: 12, y: 12, width: 400, height: 200)
        badge.update(scale: 1, imageRect: image, contentsScale: 1)
        let originalFrame = badge.frame
        badge.isHidden = false
        badge.update(scale: 1, imageRect: image, contentsScale: 1)
        #expect(!badge.isHidden && badge.frame == originalFrame)
        badge.isHidden = true
        badge.update(scale: 1, imageRect: image, contentsScale: 1)
        #expect(badge.isHidden)

        badge.update(scale: 1, imageRect: image, contentsScale: 2, limit: .maximum)
        #expect(badge.displayedText == "100% · \(C("上限", "Max"))")
        #expect(badge.contentsScale == 2)
        let text = try #require(badge.sublayers?.first as? CATextLayer)
        #expect(text.contentsScale == 2)
        let movedImage = image.offsetBy(dx: 80, dy: -20)
        badge.update(scale: 1, imageRect: movedImage, contentsScale: 2, limit: .maximum)
        #expect(badge.frame.midX == movedImage.midX)
        #expect(badge.frame.minY == movedImage.minY + 8)
        #expect(badge.isHidden)
    }

    @Test @MainActor
    func updatesNeverAnimateOrInterceptInput() throws {
        let root = CALayer()
        let badge = CaptureZoomBadge()
        root.addSublayer(badge)
        let image = CGRect(x: 12, y: 12, width: 400, height: 200)
        badge.update(scale: 1, imageRect: image, contentsScale: 2)
        badge.isHidden = false
        CATransaction.flush()
        badge.update(scale: 0.85, imageRect: image.insetBy(dx: 20, dy: 10), contentsScale: 2)
        CATransaction.flush()
        let text = try #require(badge.sublayers?.first as? CATextLayer)
        #expect(badge.animationKeys()?.isEmpty != false)
        #expect(text.animationKeys()?.isEmpty != false)
        #expect(badge.hitTest(CGPoint(x: badge.bounds.midX, y: badge.bounds.midY)) == nil)
        #expect(badge.action(forKey: "position") == nil)
        #expect(text.action(forKey: "string") == nil)
    }
}
