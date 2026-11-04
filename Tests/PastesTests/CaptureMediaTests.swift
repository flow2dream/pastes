import AppKit
import AVFoundation
import SwiftUI
import Testing
@testable import pastes

@Suite("Capture media integration", .serialized)
struct CaptureMediaTests {
    @Test @MainActor
    func movieImportsDeduplicatesAndTrimsWithoutChangingOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pastes-MovieTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Synthetic.mov")
        try await writeMovie(source)
        let original = try CaptureLibrary.fileDigest(source)
        let library = try CaptureLibrary(directory: root.appendingPathComponent("Library"))
        let item = try await library.importMedia(source)
        #expect(item.kind == .movie)
        let duplicate = try await library.importMedia(source)
        #expect(duplicate.id == item.id)
        #expect(library.visibleItems.count == 1)
        let trimmed = root.appendingPathComponent("Trimmed.mov")
        try await CaptureMovieExport.trim(source: AVURLAsset(url: library.url(for: item)),
            range: CMTimeRange(start: .zero, duration: CMTime(seconds: 0.5, preferredTimescale: 600)), destination: trimmed)
        let duration = try await AVURLAsset(url: trimmed).load(.duration)
        #expect(duration.seconds > 0 && duration.seconds < 1)
        #expect(try CaptureLibrary.fileDigest(source) == original)
        let result = try await library.importMedia(trimmed)
        #expect(result.id != item.id)
        #expect(library.visibleItems.count == 2)
    }

    @Test @MainActor
    func invalidRecordingIsNotAdded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pastes-BadMovieTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Broken.mov")
        try Data("not a movie".utf8).write(to: source)
        let library = try CaptureLibrary(directory: root.appendingPathComponent("Library"))
        do { _ = try await library.importMedia(source); Issue.record("Invalid movie was accepted") } catch {}
        #expect(library.items.isEmpty)
    }

    @Test @MainActor
    func watcherImportsOnlyNewStableMediaOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pastes-WatcherTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("Old.png")
        let image = NSImage(size: NSSize(width: 40, height: 30), flipped: false) { rect in NSColor.systemBlue.setFill(); rect.fill(); return true }
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: existing)
        // Give the pre-existing file a clearly older creation time than the watcher.
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: existing.path)
        var received: [URL] = []
        let watcher = CaptureWatcher()
        watcher.start(folder: root, acceptsAllMedia: true, onFile: { received.append($0) }, onError: { Issue.record("Watcher error: \($0)") })
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(100))
        let fresh = root.appendingPathComponent("New.png")
        try data.write(to: fresh)
        for _ in 0..<50 {
            if !received.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(received.map { $0.resolvingSymlinksInPath() } == [fresh.resolvingSymlinksInPath()])
        try await Task.sleep(for: .seconds(1.6))
        #expect(received.map { $0.resolvingSymlinksInPath() } == [fresh.resolvingSymlinksInPath()])
    }

    /// Optional offscreen visual smoke artifact; no app launch, system clipboard or capture settings.
    @Test @MainActor
    func renderShelfAndSettingsOffscreen() async throws {
        guard let output = ProcessInfo.processInfo.environment["PASTES_CAPTURE_SNAPSHOT_ROOT"] else { return }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pastes-RenderTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaultsName = "Pastes-RenderTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName); try? FileManager.default.removeItem(at: root) }
        defaults.set(true, forKey: "captureShelfEnabled")
        let board = NSPasteboard(name: .init(defaultsName)); defer { board.releaseGlobally() }
        let library = try CaptureLibrary(directory: root.appendingPathComponent("Library"))
        for (index, color) in [NSColor.systemTeal, .systemIndigo, .systemOrange].enumerated() {
            let image = NSImage(size: [NSSize(width: 640, height: 400), NSSize(width: 360, height: 640), NSSize(width: 640, height: 400)][index], flipped: false) { rect in
                color.withAlphaComponent(0.15).setFill(); rect.fill()
                color.setFill(); NSBezierPath(roundedRect: NSRect(x: 50, y: 60, width: 540, height: 280), xRadius: 15, yRadius: 15).fill()
                ("Pastes Dev · \(index + 1)" as NSString).draw(at: NSPoint(x: 100, y: 190), withAttributes: [.font: NSFont.systemFont(ofSize: 34, weight: .semibold), .foregroundColor: NSColor.white])
                return true
            }
            let data = try #require(image.tiffRepresentation)
            let item = try library.importImage(data, title: ["页面参考.png", "设计稿.png", "操作步骤.png"][index])
            if index == 0 { try library.togglePin(item.id) }
        }
        let store = try ClipboardStore(url: root.appendingPathComponent("history.sqlite"))
        let session = ClipboardSession(store: store, pasteboard: board, defaults: defaults)
        let controller = CaptureController(library: library, session: session, defaults: defaults)
        controller.lineRevealed = true
        let destination = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try await snapshot(CaptureShelfView(controller: controller, library: library), size: NSSize(width: 1000, height: 240), to: destination.appendingPathComponent("capture-shelf.png"))
        controller.updateShelfWidth(1000)
        controller.setAdaptiveRetention()
        try await snapshot(CaptureShelfView(controller: controller, library: library), size: NSSize(width: 1000, height: 210), to: destination.appendingPathComponent("capture-shelf-adaptive-sparse.png"))
        controller.setMaximumItems(20)
        try await snapshotArrivalSequence(controller: controller, destination: destination)
        let previewImage = try #require(NSImage(contentsOf: library.url(for: library.visibleItems[0])))
        try await snapshot(CaptureImagePreview(image: previewImage, onClose: {}), size: NSSize(width: 720, height: 450), to: destination.appendingPathComponent("capture-reference-borderless.png"))
        let sample = try #require(library.visibleItems.first)
        let bytes = try Data(contentsOf: library.url(for: sample))
        for index in 0..<12 { _ = try library.importImage(bytes, title: "Overflow \(index)", forceNew: true) }
        try await snapshot(CaptureShelfView(controller: controller, library: library), size: NSSize(width: 1000, height: 210), to: destination.appendingPathComponent("capture-shelf-overflow.png"))
        controller.updateShelfWidth(1000)
        controller.setAdaptiveRetention()
        try await snapshot(CaptureShelfView(controller: controller, library: library), size: NSSize(width: 1000, height: 210), to: destination.appendingPathComponent("capture-shelf-adaptive.png"))
        try await snapshot(CaptureSettingsView(controller: controller), size: NSSize(width: 520, height: 840), to: destination.appendingPathComponent("capture-settings-adaptive.png"))
        controller.setCustomMaximumItems(37)
        try await snapshot(CaptureSettingsView(controller: controller), size: NSSize(width: 520, height: 840), to: destination.appendingPathComponent("capture-settings.png"))
    }

    @MainActor private func snapshotArrivalSequence(controller: CaptureController, destination: URL) async throws {
        let size = NSSize(width: 1000, height: 210)
        let host = NSHostingView(rootView: CaptureShelfView(controller: controller, library: controller.library).frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.isReleasedWhenClosed = false
        defer { window.close() }
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(1800))
        let source = try #require(controller.library.visibleItems.first)
        _ = try controller.library.importImage(Data(contentsOf: controller.library.url(for: source)), title: "Arrival", forceNew: true)
        for (index, delay) in [80, 200, 350, 1000].enumerated() {
            try await Task.sleep(for: .milliseconds(delay))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent("capture-arrival-\(index).png"))
        }
    }

    @MainActor private func snapshot<V: View>(_ content: V, size: NSSize, to url: URL) async throws {
        let host = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.isReleasedWhenClosed = false
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(1800))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
        window.close()
    }

    private func writeMovie(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<20 {
            var buffer: CVPixelBuffer?
            #expect(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess)
            let pixel = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            memset(CVPixelBufferGetBaseAddress(pixel), Int32(frame * 10), CVPixelBufferGetDataSize(pixel))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
            #expect(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }
}
