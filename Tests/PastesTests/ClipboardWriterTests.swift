import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import pastes

@Suite("Clipboard writing")
struct ClipboardWriterTests {
    @Test @MainActor
    func preservesPlainTextAndRTFAndReturnsTheWrittenGeneration() throws {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let writer = ClipboardWriter(pasteboard: board)
        let text = "synthetic rich 中文"
        let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.boldSystemFont(ofSize: 16)])
        let rtf = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])

        let generation = try writer.write(ClipboardItem(content: text, rtfData: rtf))
        #expect(generation == board.changeCount)
        #expect(board.string(forType: .string) == text)
        #expect(board.data(forType: .rtf) == rtf)

        try writer.write(ClipboardItem(content: "plain replacement"))
        #expect(board.string(forType: .string) == "plain replacement")
        #expect(board.data(forType: .rtf) == nil)
    }

    @Test @MainActor
    func advertisesPNGAndTIFFUsingTheirActualEncodings() throws {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let writer = ClipboardWriter(pasteboard: board)
        for (format, type, identifier) in [
            (NSBitmapImageRep.FileType.png, NSPasteboard.PasteboardType.png, UTType.png.identifier),
            (.tiff, .tiff, UTType.tiff.identifier)
        ] {
            let original = try makeImage(format)
            try writer.write(ClipboardItem(content: "[Image]", imageData: original))
            #expect(board.types?.contains(type) == true)
            let data = try #require(board.data(forType: type))
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let actualType = try #require(CGImageSourceGetType(source))
            #expect(actualType as String == identifier)
            #expect(data == original)
        }
    }

    @Test @MainActor
    func convertsOtherImageFormatsToGenuineTIFF() throws {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let jpeg = try makeImage(.jpeg)
        try ClipboardWriter(pasteboard: board).write(ClipboardItem(content: "[Image]", imageData: jpeg))
        #expect(board.types?.contains(.tiff) == true)
        let data = try #require(board.data(forType: .tiff))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let actualType = try #require(CGImageSourceGetType(source))
        #expect(actualType as String == UTType.tiff.identifier)
    }

    @Test @MainActor
    func rejectingAnInvalidImagePreservesThePreviousClipboard() {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        board.setString("synthetic existing clipboard", forType: .string)
        let generation = board.changeCount
        let item = ClipboardItem(content: "[Image]", imageData: Data([0, 1, 2, 255]))

        #expect { try ClipboardWriter(pasteboard: board).write(item) } throws: { _ in true }
        #expect(board.changeCount == generation)
        #expect(board.string(forType: .string) == "synthetic existing clipboard")
    }

    @MainActor private func makeBoard() -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("PastesWriterTests-\(UUID().uuidString)"))
        board.clearContents()
        return board
    }

    @MainActor private func makeImage(_ type: NSBitmapImageRep.FileType) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                                  bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                                  bytesPerRow: 6, bitsPerPixel: 24))
        let color = NSColor(deviceRed: 0.7, green: 0.2, blue: 0.4, alpha: 1)
        for y in 0..<2 { for x in 0..<2 { bitmap.setColor(color, atX: x, y: y) } }
        return try #require(bitmap.representation(using: type, properties: [:]))
    }
}
