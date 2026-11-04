import AppKit
import Testing
@testable import pastes

@Suite("Capture edit save options")
struct CaptureSaveOptionsTests {
    @Test @MainActor
    func overwritePreservesIdentityPinOrderAndSurvivesReopen() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try CaptureLibrary(directory: root)
        let item = try library.importImage(png(.red), title: "Original.png")
        try library.togglePin(item.id)
        let historyID = UUID()
        let updated = try library.overwriteImage(id: item.id, expectedDigest: item.digest, data: png(.blue), historyID: historyID)
        #expect(updated.id == item.id)
        #expect(updated.title == item.title)
        #expect(updated.created == item.created)
        #expect(updated.isPinned)
        #expect(updated.digest != item.digest)
        #expect(updated.historyID == historyID)
        #expect(library.items.count == 1)
        #expect(try CaptureLibrary(directory: root).items == library.items)
        let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: library.url(for: updated))))
        #expect(try #require(bitmap.colorAt(x: 4, y: 4)?.usingColorSpace(.deviceRGB)).blueComponent > 0.9)
    }
    @Test @MainActor
    func saveCopyMakesDistinctItemEvenWithoutChanges() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try CaptureLibrary(directory: root)
        let bytes = try png(.red)
        let original = try library.importImage(bytes, title: "Original")
        let copy = try library.importImage(bytes, title: "Copy", forceNew: true)
        #expect(original.id != copy.id)
        #expect(original.digest == copy.digest)
        #expect(library.items.count == 2)
    }
    @Test @MainActor
    func staleEditorCannotOverwriteNewerImage() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try CaptureLibrary(directory: root)
        let original = try library.importImage(png(.red), title: "Original")
        let updated = try library.overwriteImage(id: original.id, expectedDigest: original.digest, data: png(.blue))
        #expect(throws: (any Error).self) { try library.overwriteImage(id: original.id, expectedDigest: original.digest, data: png(.green)) }
        #expect(library.items == [updated])
    }
    @Test @MainActor
    func failedOverwritePreservesOriginalAndRollsBackHistory() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try CaptureLibrary(directory: root.appendingPathComponent("Library"))
        let store = try ClipboardStore(url: root.appendingPathComponent("history.sqlite"))
        let original = try library.importImage(png(.red), title: "Original")
        let originalBytes = try Data(contentsOf: library.url(for: original))
        let manifest = library.directory.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: true)
        let bytes = try png(.blue)
        #expect(throws: (any Error).self) {
            try store.addEditedImage(bytes, limit: 0) { historyID in
                try library.overwriteImage(id: original.id, expectedDigest: original.digest, data: bytes, historyID: historyID)
            }
        }
        #expect(store.items.isEmpty)
        #expect(library.items == [original])
        #expect(try Data(contentsOf: library.url(for: original)) == originalBytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.directory.path).count == 2)
    }
    @Test @MainActor
    func editorDispatchesTheChosenSaveAction() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.png")
        let data = try png(.red); try data.write(to: source)
        var copies = 0, overwrites = 0
        let editor = try CaptureImageEditor(url: source, onSaved: { url in
            #expect(FileManager.default.fileExists(atPath: url.path)); copies += 1
        }, onOverwrite: { url in
            #expect(FileManager.default.fileExists(atPath: url.path)); overwrites += 1
        })
        #expect(editor.canOverwrite)
        editor.overwrite()
        for _ in 0..<100 { if !editor.saving { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(overwrites == 1 && copies == 0)
        editor.save()
        for _ in 0..<100 { if !editor.saving { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(overwrites == 1 && copies == 1)
        #expect(try Data(contentsOf: source) == data)
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pastes-SaveOptions-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @MainActor private func png(_ color: NSColor) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let rgb = try #require(color.usingColorSpace(.deviceRGB))
        let pixels = try #require(bitmap.bitmapData)
        for x in 0..<20 { for y in 0..<20 {
            let offset = y * bitmap.bytesPerRow + x * 4
            pixels[offset] = UInt8((rgb.redComponent * 255).rounded())
            pixels[offset + 1] = UInt8((rgb.greenComponent * 255).rounded())
            pixels[offset + 2] = UInt8((rgb.blueComponent * 255).rounded())
            pixels[offset + 3] = 255
        } }
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}
