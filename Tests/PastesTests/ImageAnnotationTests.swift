import AppKit
import Testing
import SwiftUI
@testable import pastes

@Suite("Image annotation editor", .serialized)
struct ImageAnnotationTests {
    @Test @MainActor
    func reverseDragCreatesExactRectangleThenSupportsMoveResizeUndoRedo() throws {
        let (document, directory) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let canvas = ImageAnnotationCanvas(document: document)
        canvas.frame = CGRect(x: 0, y: 0, width: 848, height: 648)
        document.tool = .rectangle
        canvas.begin(at: CGPoint(x: 300, y: 250))
        canvas.drag(to: CGPoint(x: 100, y: 80)); canvas.end()
        let shape = try #require(document.annotations.first)
        #expect(shape.bounds == CGRect(x: 100, y: 80, width: 200, height: 170))
        document.tool = .select
        canvas.begin(at: CGPoint(x: 200, y: 150)); canvas.drag(to: CGPoint(x: 220, y: 180)); canvas.end()
        #expect(document.annotations[0].bounds == CGRect(x: 120, y: 110, width: 200, height: 170))
        canvas.begin(at: CGPoint(x: 320, y: 280)); canvas.drag(to: CGPoint(x: 380, y: 300)); canvas.end()
        #expect(document.annotations[0].bounds == CGRect(x: 120, y: 110, width: 260, height: 190))
        document.undo()
        #expect(document.annotations[0].bounds == CGRect(x: 120, y: 110, width: 200, height: 170))
        document.undo()
        #expect(document.annotations[0].bounds == shape.bounds)
        document.redo()
        #expect(document.annotations[0].bounds.origin == CGPoint(x: 120, y: 110))
    }

    @Test @MainActor
    func windowCoordinatesMapToImagePixelsAtDifferentSizes() throws {
        let (document, directory) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let canvas = ImageAnnotationCanvas(document: document)
        for size in [CGSize(width: 848, height: 648), CGSize(width: 448, height: 348), CGSize(width: 1100, height: 600)] {
            canvas.frame = CGRect(origin: .zero, size: size)
            let rect = canvas.imageRect
            let mapped = try #require(canvas.imagePoint(CGPoint(x: rect.midX, y: rect.midY), clamp: false))
            #expect(abs(mapped.x - 400) < 0.001)
            #expect(abs(mapped.y - 300) < 0.001)
            #expect(canvas.imagePoint(.zero, clamp: false) == nil)
            #expect(canvas.imagePoint(.zero, clamp: true) == .zero)
        }
    }

    @Test @MainActor
    func cancelledDragDoesNotModifyHistoryAndNewEditClearsRedo() throws {
        let (document, directory) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let canvas = ImageAnnotationCanvas(document: document)
        canvas.frame = CGRect(x: 0, y: 0, width: 848, height: 648)
        document.tool = .ellipse
        canvas.begin(at: CGPoint(x: 50, y: 60)); canvas.drag(to: CGPoint(x: 200, y: 180)); canvas.cancelGesture()
        #expect(document.annotations.isEmpty)
        #expect(!document.canUndo)
        canvas.begin(at: CGPoint(x: 50, y: 60)); canvas.drag(to: CGPoint(x: 200, y: 180)); canvas.end()
        document.undo(); #expect(document.canRedo)
        document.tool = .arrow
        canvas.begin(at: CGPoint(x: 20, y: 20)); canvas.drag(to: CGPoint(x: 400, y: 200)); canvas.end()
        #expect(!document.canRedo)
        #expect(document.annotations.first?.tool == .arrow)
        document.deleteSelected(); #expect(document.annotations.isEmpty)
        document.undo(); #expect(document.annotations.count == 1)
    }

    @Test @MainActor
    func exportPreservesResolutionAndOriginalAndDoesNotIncludeSelectionHandles() throws {
        let (document, directory) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let originalURL = directory.appendingPathComponent("original.png")
        let before = try Data(contentsOf: originalURL)
        document.add(ImageAnnotation(id: UUID(), tool: .rectangle, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 300, y: 300), points: [], color: .red, lineWidth: 10, text: ""))
        document.tool = .select
        let result = try #require(NSBitmapImageRep(data: document.exportPNG()))
        #expect(result.pixelsWide == 800 && result.pixelsHigh == 600)
        // NSBitmapImageRep pixel rows are top-down; the rectangle's bottom edge is at row 500.
        let edge = try #require(result.colorAt(x: 200, y: 500)?.usingColorSpace(.deviceRGB))
        #expect(edge.redComponent > 0.9 && edge.greenComponent < 0.2)
        let center = try #require(result.colorAt(x: 200, y: 400)?.usingColorSpace(.deviceRGB))
        #expect(center.redComponent > 0.9 && center.greenComponent > 0.9)
        #expect(try Data(contentsOf: originalURL) == before)
    }

    @Test @MainActor
    func failedSaveRetainsEditableAnnotationsAndReportsFailure() async throws {
        let (_, directory) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let editor = try CaptureImageEditor(url: directory.appendingPathComponent("original.png"), onSaved: { _ in throw CaptureError.invalidMedia })
        editor.document.add(ImageAnnotation(id: UUID(), tool: .ellipse, start: CGPoint(x: 50, y: 50), end: CGPoint(x: 200, y: 200), points: [], color: .red, lineWidth: 4, text: ""))
        editor.save()
        for _ in 0..<100 {
            if !editor.saving { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!editor.saving)
        #expect(editor.errorMessage != nil)
        #expect(editor.document.annotations.count == 1)
        #expect(editor.document.canUndo)
    }

    @Test @MainActor
    func renderImageEditorOffscreen() async throws {
        guard let output = ProcessInfo.processInfo.environment["PASTES_CAPTURE_SNAPSHOT_ROOT"] else { return }
        _ = NSApplication.shared
        let (_, directory) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let editor = try CaptureImageEditor(url: directory.appendingPathComponent("original.png"), onSaved: { _ in }, onOverwrite: { _ in })
        let document = editor.document
        document.add(ImageAnnotation(id: UUID(), tool: .rectangle, start: CGPoint(x: 80, y: 160), end: CGPoint(x: 360, y: 420), points: [], color: .systemRed, lineWidth: 5, text: ""))
        document.add(ImageAnnotation(id: UUID(), tool: .ellipse, start: CGPoint(x: 440, y: 240), end: CGPoint(x: 690, y: 430), points: [], color: .systemBlue, lineWidth: 5, text: ""))
        document.add(ImageAnnotation(id: UUID(), tool: .arrow, start: CGPoint(x: 190, y: 90), end: CGPoint(x: 480, y: 250), points: [], color: .systemOrange, lineWidth: 7, text: ""))
        document.tool = .select
        document.selection = document.annotations.first?.id
        let host = NSHostingView(rootView: CaptureImageEditorView(editor: editor, document: document).frame(width: 1040, height: 760))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1040, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        host.frame = CGRect(x: 0, y: 0, width: 1040, height: 760)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let target = URL(fileURLWithPath: output).appendingPathComponent("image-editor.png")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target); window.close()
    }

    @MainActor private func fixture() throws -> (ImageAnnotationDocument, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Pastes-AnnotationTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = NSImage(size: CGSize(width: 800, height: 600), flipped: false) { rect in NSColor.white.setFill(); rect.fill(); return true }
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let url = directory.appendingPathComponent("original.png"); try data.write(to: url)
        return (try ImageAnnotationDocument(url: url), directory)
    }
}
