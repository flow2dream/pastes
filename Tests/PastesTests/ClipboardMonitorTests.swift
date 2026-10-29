import AppKit
import Foundation
import Testing
@testable import pastes

@Suite("Clipboard monitoring")
struct ClipboardMonitorTests {
    @Test @MainActor
    func capturesTextAndRichTextWithoutRepeatingAnUnchangedGeneration() throws {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let monitor = ClipboardMonitor(pasteboard: board)
        var texts: [String] = []
        var richData: [Data?] = []
        monitor.start(interval: 3600) { text, rtf in
            texts.append(text)
            richData.append(rtf)
        }
        defer { monitor.stop() }

        board.clearContents()
        #expect(board.setString("synthetic plain text", forType: .string))
        monitor.checkPasteboard()
        monitor.checkPasteboard()
        #expect(texts == ["synthetic plain text"])
        #expect(richData.count == 1 && richData[0] == nil)

        let text = "QA rich 中文测试"
        let rtf = try makeRTF(text)
        board.declareTypes([.string, .rtf], owner: nil)
        #expect(board.setData(rtf, forType: .rtf))
        #expect(board.setString(text, forType: .string))
        monitor.checkPasteboard()
        #expect(texts == ["synthetic plain text", text])
        let receivedRTF = richData.last ?? nil
        #expect(receivedRTF == rtf)
    }

    @Test @MainActor
    func capturesRTFWhenNoPlainTextRepresentationIsAdvertised() throws {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let monitor = ClipboardMonitor(pasteboard: board)
        var capturedText: String?
        var capturedRTF: Data?
        monitor.start(interval: 3600) { capturedText = $0; capturedRTF = $1 }
        defer { monitor.stop() }
        let text = "RTF only 中文"
        let rtf = try makeRTF(text)
        board.declareTypes([.rtf], owner: nil)
        #expect(board.setData(rtf, forType: .rtf))

        monitor.checkPasteboard()
        #expect(capturedText == text)
        #expect(capturedRTF == rtf)
    }

    @Test @MainActor
    func capturesBothPNGAndTIFFImages() throws {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let monitor = ClipboardMonitor(pasteboard: board)
        var images: [Data] = []
        monitor.onCopyImage = { images.append($0) }
        monitor.start(interval: 3600) { _, _ in Issue.record("An image was treated as text.") }
        defer { monitor.stop() }
        let png = try makeImage(.png)
        let tiff = try makeImage(.tiff)
        for (type, data) in [(NSPasteboard.PasteboardType.png, png), (.tiff, tiff)] {
            board.declareTypes([type], owner: nil)
            #expect(board.setData(data, forType: type))
            monitor.checkPasteboard()
        }
        // macOS can expose a synthesized TIFF representation for a PNG pasteboard.
        // Verify that both copied images survive decoding with their pixels intact.
        #expect(images.count == 2)
        for (data, original) in zip(images, [png, tiff]) {
            let bitmap = try #require(NSBitmapImageRep(data: data))
            let reference = try #require(NSBitmapImageRep(data: original))
            #expect(bitmap.pixelsWide == 2 && bitmap.pixelsHigh == 2)
            let pixel = try #require(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
            let expected = try #require(reference.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
            #expect(abs(pixel.redComponent - expected.redComponent) < 0.01)
            #expect(abs(pixel.greenComponent - expected.greenComponent) < 0.01)
            #expect(abs(pixel.blueComponent - expected.blueComponent) < 0.01)
            #expect(abs(pixel.alphaComponent - expected.alphaComponent) < 0.005)
        }
    }

    @Test @MainActor
    func skipsOnlyTheAcknowledgedWriteAndCapturesAFasterExternalUpdate() throws {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let monitor = ClipboardMonitor(pasteboard: board)
        var texts: [String] = []
        monitor.start(interval: 3600) { text, _ in texts.append(text) }
        defer { monitor.stop() }
        let writer = ClipboardWriter(pasteboard: board)

        let ownGeneration = try writer.write(ClipboardItem(content: "chosen history"))
        monitor.acknowledgeOwnWrite(changeCount: ownGeneration)
        monitor.checkPasteboard()
        #expect(texts.isEmpty)

        let secondOwnGeneration = try writer.write(ClipboardItem(content: "another history selection"))
        monitor.acknowledgeOwnWrite(changeCount: secondOwnGeneration)
        board.clearContents()
        #expect(board.setString("new external copy before next poll", forType: .string))
        monitor.checkPasteboard()
        monitor.checkPasteboard()
        #expect(texts == ["new external copy before next poll"])
    }

    @Test @MainActor
    func retriesAnEmptyGenerationWhenDataArrivesAfterTheFirstPoll() {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let monitor = ClipboardMonitor(pasteboard: board)
        var texts: [String] = []
        monitor.start(interval: 3600) { text, _ in texts.append(text) }
        defer { monitor.stop() }
        let generation = board.clearContents()
        monitor.checkPasteboard()
        #expect(texts.isEmpty)

        #expect(board.setString("late same-generation payload", forType: .string))
        #expect(board.changeCount == generation)
        monitor.checkPasteboard()
        monitor.checkPasteboard()
        #expect(texts == ["late same-generation payload"])
    }

    @Test @MainActor
    func waitsForAdvertisedRichTextToBecomeAvailable() throws {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let monitor = ClipboardMonitor(pasteboard: board)
        var received: [Data?] = []
        monitor.start(interval: 3600) { _, rtf in received.append(rtf) }
        defer { monitor.stop() }
        let text = "delayed rich representation"
        let rtf = try makeRTF(text)
        let generation = board.declareTypes([.string, .rtf], owner: nil)
        #expect(board.setString(text, forType: .string))
        monitor.checkPasteboard()
        #expect(received.isEmpty)

        #expect(board.setData(rtf, forType: .rtf))
        #expect(board.changeCount == generation)
        monitor.checkPasteboard()
        #expect(received.count == 1 && received[0] == rtf)
    }

    @Test @MainActor
    func ignoresNonImageFilesEvenWhenTheyAdvertiseAThumbnail() throws {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let monitor = ClipboardMonitor(pasteboard: board)
        var captured = 0
        monitor.onCopyImage = { _ in captured += 1 }
        monitor.start(interval: 3600) { _, _ in captured += 1 }
        defer { monitor.stop() }
        board.declareTypes([.fileURL, .png], owner: nil)
        #expect(board.setString("file:///tmp/PastesSyntheticDocument.pdf", forType: .fileURL))
        #expect(board.setData(try makeImage(.png), forType: .png))

        monitor.checkPasteboard()
        #expect(captured == 0)
    }

    @Test @MainActor
    func startingTwiceThenStoppingLeavesNoPollingTimer() async throws {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let monitor = ClipboardMonitor(pasteboard: board)
        var captured: [String] = []
        monitor.start(interval: 0.01) { text, _ in captured.append(text) }
        board.clearContents()
        #expect(board.setString("captured while running", forType: .string))
        try await Task.sleep(for: .milliseconds(80))
        #expect(captured == ["captured while running"])

        monitor.start(interval: 0.01) { text, _ in captured.append(text) }
        monitor.stop()
        monitor.stop()
        board.clearContents()
        #expect(board.setString("must not be captured after stop", forType: .string))

        try await Task.sleep(for: .milliseconds(80))
        #expect(captured == ["captured while running"])
    }

    @MainActor private func makeBoard() -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("PastesMonitorTests-\(UUID().uuidString)"))
        board.clearContents()
        return board
    }

    @MainActor private func makeRTF(_ text: String) throws -> Data {
        let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.boldSystemFont(ofSize: 18)])
        return try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    @MainActor private func makeImage(_ type: NSBitmapImageRep.FileType) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                                  bytesPerRow: 8, bitsPerPixel: 32))
        let color = NSColor(deviceRed: 0.2, green: 0.4, blue: 0.7, alpha: 1)
        for y in 0..<2 { for x in 0..<2 { bitmap.setColor(color, atX: x, y: y) } }
        return try #require(bitmap.representation(using: type, properties: [:]))
    }
}
