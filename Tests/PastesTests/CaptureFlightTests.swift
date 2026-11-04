import Foundation
import Testing
@testable import pastes

@Suite("Source-to-shelf flight")
struct CaptureFlightTests {
    @Test func startsAtSourceAndEndsAtTheActualCard() {
        let source = CGRect(x: -1100, y: 140, width: 220, height: 140)
        let target = CGRect(x: -650, y: 820, width: 136, height: 86)
        let path = CaptureFlightPath(origin: source, target: target)
        #expect(path.frame(at: 0) == source)
        #expect(path.frame(at: 1) == target)
        #expect(path.frame(at: -1) == source)
        #expect(path.frame(at: 2) == target)
    }

    @Test func imageBoundsUseImageCenterAndConvertAcrossScreens() {
        let rect = CaptureImageSource.appKitRect(position: CGPoint(x: -800, y: 200), size: CGSize(width: 400, height: 300), primaryHeight: 900)
        #expect(rect == CGRect(x: -800, y: 400, width: 400, height: 300))
        #expect(CaptureImageSource.matchesImage(rect, imageSize: CGSize(width: 1600, height: 1200)))
        #expect(!CaptureImageSource.matchesImage(rect, imageSize: CGSize(width: 300, height: 900)))
        #expect(!CaptureImageSource.matchesImage(.zero, imageSize: CGSize(width: 1600, height: 1200)))
    }

    @Test func movesAndShrinksContinuouslyWithoutOvershootingTheDestination() {
        let path = CaptureFlightPath(origin: CGRect(x: 100, y: 100, width: 220, height: 140),
                                     target: CGRect(x: 900, y: 800, width: 136, height: 86))
        var previous = path.start
        for step in 1...100 {
            let frame = path.frame(at: Double(step) / 100)
            #expect(frame.midX >= previous.midX)
            #expect(frame.midX <= path.target.midX)
            #expect(frame.midY >= previous.midY)
            #expect(frame.midY <= path.target.midY)
            #expect(frame.width <= previous.width)
            previous = frame
        }
        let firstStep = path.frame(at: 0.01).midX - path.start.midX
        let middleStep = path.frame(at: 0.51).midX - path.frame(at: 0.5).midX
        let lastStep = path.target.midX - path.frame(at: 0.99).midX
        #expect(firstStep < middleStep / 10)
        #expect(lastStep < middleStep / 10)
    }
}
