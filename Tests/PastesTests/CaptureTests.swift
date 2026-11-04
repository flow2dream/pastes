import AppKit
import Foundation
import Testing
@testable import pastes

@Suite("Capture library and isolation")
struct CaptureTests {
    @Test @MainActor
    func importsDeduplicatesPinsAndReopensWithoutTouchingSource() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Original.png")
        let bytes = try image(); try bytes.write(to: source)
        let library = try CaptureLibrary(directory: root.appendingPathComponent("Library"))
        let first = try library.importFile(source)
        let same = try library.importFile(source)
        #expect(same.id == first.id)
        #expect(library.visibleItems.count == 1)
        try library.togglePin(first.id)
        let reopened = try CaptureLibrary(directory: library.directory)
        #expect(reopened.visibleItems.first?.isPinned == true)
        #expect(try Data(contentsOf: source) == bytes)
        #expect(library.url(for: first) != source)
    }

    @Test @MainActor
    func removalUndoAndPurgeLeaveHistoryAndSourceIntact() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try ClipboardStore(url: root.appendingPathComponent("history.sqlite"))
        let bytes = try image()
        let historyID = try store.addImage(bytes, limit: 0)
        let library = try CaptureLibrary(directory: root.appendingPathComponent("Library"))
        let item = try library.importImage(bytes, title: "Test", historyID: historyID)
        try library.remove(item.id)
        #expect(library.visibleItems.isEmpty)
        #expect(library.canUndo)
        #expect(FileManager.default.fileExists(atPath: library.url(for: item).path))
        #expect(store.items.first?.id == historyID)
        try library.undo()
        #expect(library.visibleItems.count == 1)
        #expect(!library.canUndo)
        try library.remove(item.id)
        try library.purgeHidden()
        #expect(library.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: library.url(for: item).path))
        #expect(store.items.first?.id == historyID)
    }

    @Test @MainActor
    func failedManifestSaveDoesNotPublishOrLeakNewImage() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try CaptureLibrary(directory: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("library.json"), withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try library.importImage(image(), title: "Test") }
        #expect(library.items.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["library.json"])
    }

    @Test @MainActor
    func corruptManifestAndPathTraversalAreRejectedWithoutOverwriting() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("library.json")
        let bad = Data("not json".utf8); try bad.write(to: path)
        #expect(throws: (any Error).self) { try CaptureLibrary(directory: root) }
        #expect(try Data(contentsOf: path) == bad)
        let entry = CaptureItem(id: UUID(), filename: "../outside.png", title: "Bad", kind: .image, created: Date(), digest: "x")
        try JSONEncoder().encode([entry]).write(to: path)
        #expect(throws: (any Error).self) { try CaptureLibrary(directory: root) }
    }

    @Test @MainActor
    func developmentAndProductionLibrariesDoNotShareRecords() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let production = try CaptureLibrary(directory: root.appendingPathComponent("com.pastes.app.pastes/CaptureLibrary"))
        let development = try CaptureLibrary(directory: root.appendingPathComponent("com.pastes.app.pastes.dev/CaptureLibrary"))
        try development.importImage(image(), title: "Dev")
        #expect(development.items.count == 1)
        #expect(production.items.isEmpty)
    }

    @Test
    func stableFilesAreRetriedUntilAcknowledgedAndChangesAreReimported() {
        var tracker = CaptureStabilityTracker()
        let url = URL(fileURLWithPath: "/tmp/synthetic-capture.png")
        let stamp = CaptureStabilityTracker.Stamp(size: 5, modified: Date())
        #expect(tracker.candidates([url: stamp]).isEmpty)
        #expect(tracker.candidates([url: stamp]) == [url])
        #expect(tracker.candidates([url: stamp]) == [url])
        tracker.acknowledge(url)
        #expect(tracker.candidates([url: stamp]).isEmpty)
        let changed = CaptureStabilityTracker.Stamp(size: 10, modified: stamp.modified)
        #expect(tracker.candidates([url: changed]).isEmpty)
        #expect(tracker.candidates([url: changed]) == [url])
        #expect(tracker.candidates([:]).isEmpty)
        #expect(tracker.candidates([url: changed]).isEmpty)
    }

    @Test @MainActor
    func sessionCapturesWithoutAnyWindowAndSuppressesOwnCopy() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let board = NSPasteboard(name: .init("Pastes-CaptureTests-\(UUID())"))
        defer { board.releaseGlobally() }
        let store = try ClipboardStore(url: root.appendingPathComponent("history.sqlite"))
        let session = ClipboardSession(store: store, pasteboard: board)
        session.start(); defer { session.stop() }
        board.clearContents(); board.setString("external", forType: .string)
        session.monitor.checkPasteboard()
        #expect(store.items.count == 1)
        try session.copy(try #require(store.items.first))
        session.monitor.checkPasteboard()
        #expect(store.items.count == 1)
        board.clearContents(); board.setString("next external", forType: .string)
        session.monitor.checkPasteboard()
        #expect(store.items.count == 2)
    }

    @Test @MainActor
    func privateClipboardContentIsNeverStored() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let board = NSPasteboard(name: .init("Pastes-PrivateTests-\(UUID())"))
        defer { board.releaseGlobally() }
        let store = try ClipboardStore(url: root.appendingPathComponent("history.sqlite"))
        let session = ClipboardSession(store: store, pasteboard: board)
        session.start(); defer { session.stop() }
        board.declareTypes([.string, .init("org.nspasteboard.ConcealedType")], owner: nil)
        board.setString("secret", forType: .string)
        session.monitor.checkPasteboard()
        #expect(store.items.isEmpty)
    }

    @Test @MainActor
    func repeatedImageMovesToFrontWithoutDuplicatingOrLosingPin() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try ClipboardStore(url: root.appendingPathComponent("history.sqlite"))
        let data = try image()
        let id = try store.addImage(data, limit: 0)
        try store.togglePin(id: id)
        try store.addText("More recent", limit: 0)
        #expect(store.items.first?.id != id)
        #expect(try store.addImage(data, limit: 0) == id)
        #expect(store.items.first?.id == id)
        #expect(store.items.first?.isPinned == true)
        #expect(store.items.count == 2)
    }

    @Test @MainActor
    func finderMovePreservesLibraryForUndo() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try CaptureLibrary(directory: root.appendingPathComponent("Library"))
        let item = try library.importImage(image(), title: "Capture.png")
        let original = try Data(contentsOf: library.url(for: item))
        let transfer = try CaptureDragFile(source: library.url(for: item), item: item)
        defer { try? FileManager.default.removeItem(at: transfer.directory) }
        let target = root.appendingPathComponent("Saved.png")
        try FileManager.default.moveItem(at: transfer.file, to: target)
        var finished = false
        transfer.finish(operation: .move, onFiled: { value in
            try? library.remove(value.id); finished = true
        }, onError: { Issue.record("Drag error: \($0)") })
        for _ in 0..<10 {
            if finished { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(finished)
        #expect(try Data(contentsOf: target) == original)
        #expect(try Data(contentsOf: library.url(for: item)) == original)
        #expect(library.visibleItems.isEmpty)
        try library.undo()
        #expect(library.visibleItems.count == 1)
    }

    @Test @MainActor
    func topEdgeTriggerCoversWholeDisplayIncludingExactBoundary() {
        let screen = CGRect(x: -1440, y: 200, width: 1440, height: 900)
        for x in [-1440.0, -1000, -720, -1] {
            #expect(CaptureShelfPanel.isAtTopEdge(CGPoint(x: x, y: 1100), screen: screen))
            #expect(CaptureShelfPanel.isAtTopEdge(CGPoint(x: x, y: 1096), screen: screen))
        }
        #expect(!CaptureShelfPanel.isAtTopEdge(CGPoint(x: -720, y: 1090), screen: screen))
        #expect(!CaptureShelfPanel.isAtTopEdge(CGPoint(x: -720, y: 1101), screen: screen))
        #expect(!CaptureShelfPanel.isAtTopEdge(CGPoint(x: 1, y: 1100), screen: screen))
    }

    @Test @MainActor
    func hoverPreviewFitsBelowPhotoAndClampsToOffsetDisplay() throws {
        let screen = CGRect(x: -1440, y: 200, width: 1440, height: 900)
        let anchor = CGRect(x: -1400, y: 930, width: 140, height: 100)
        let landscape = try #require(CaptureHoverPreview.frame(image: CGSize(width: 1920, height: 1080), anchor: anchor, screen: screen))
        #expect(landscape.maxY < anchor.minY)
        #expect(screen.contains(landscape))
        #expect(abs(landscape.width / landscape.height - 1920.0 / 1080) < 0.001)
        #expect(landscape.width > anchor.width)
        let portrait = try #require(CaptureHoverPreview.frame(image: CGSize(width: 400, height: 1800), anchor: anchor, screen: screen))
        #expect(screen.contains(portrait))
        #expect(portrait.maxY < anchor.minY)
        #expect(portrait.height <= 460)
        #expect(CaptureHoverPreview.frame(image: .zero, anchor: anchor, screen: screen) == nil)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Pastes-CaptureTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @MainActor private func image() throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<8 { for y in 0..<8 { bitmap.setColor(.systemTeal, atX: x, y: y) } }
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}

@Suite("Legacy capture settings recovery")
struct CaptureInboxTests {
    @Test @MainActor
    func legacyJournalRestoresExistingAndAbsentKeysExactly() {
        let fixture = Fixture(); defer { fixture.cleanup() }
        let original = fixture.system
        fixture.installLegacyJournal()
        fixture.inbox.restore()
        #expect(NSDictionary(dictionary: fixture.system).isEqual(to: original))
        #expect(fixture.system["location-screenshot"] == nil)
        #expect(fixture.system["target-screenrecording"] == nil)
        #expect(Set(fixture.writtenKeys) == Set(fixture.legacyValues.keys))
        #expect(fixture.synchronizations == 1)
        #expect(fixture.defaults.dictionary(forKey: fixture.snapshotKey) == nil)
    }

    @Test @MainActor
    func noJournalNeverWritesSystemSettingsEvenAtTheLegacyDestination() {
        let fixture = Fixture(); defer { fixture.cleanup() }
        fixture.system = fixture.legacyValues
        let original = fixture.system
        fixture.inbox.restore()
        #expect(NSDictionary(dictionary: fixture.system).isEqual(to: original))
        #expect(fixture.writtenKeys.isEmpty)
        #expect(fixture.synchronizations == 0)
    }

    @Test @MainActor
    func externalSettingsChangesWinOverRestoration() {
        let fixture = Fixture(); defer { fixture.cleanup() }
        fixture.installLegacyJournal()
        fixture.system["show-thumbnail"] = true
        fixture.system["target"] = "clipboard"
        fixture.inbox.restore()
        #expect(fixture.system["target"] as? String == "clipboard")
        #expect(fixture.system["show-thumbnail"] as? Bool == true)
        #expect(fixture.system["location"] as? String == "/original")
        #expect(!fixture.writtenKeys.contains("target"))
        #expect(!fixture.writtenKeys.contains("show-thumbnail"))
    }

    @Test @MainActor
    func recoveryAfterCrashConsumesLegacyJournalOnlyOnce() {
        let fixture = Fixture(); defer { fixture.cleanup() }
        let original = fixture.system
        fixture.installLegacyJournal()
        let recovered = fixture.makeInbox()
        recovered.restore()
        #expect(NSDictionary(dictionary: fixture.system).isEqual(to: original))
        let writesAfterRecovery = fixture.writtenKeys.count
        let syncsAfterRecovery = fixture.synchronizations
        #expect(writesAfterRecovery > 0)
        #expect(fixture.defaults.dictionary(forKey: fixture.snapshotKey) == nil)

        // A later launch must not reapply or restore anything without a journal.
        fixture.system["location"] = "/new-user-destination"
        fixture.makeInbox().restore()
        #expect(fixture.system["location"] as? String == "/new-user-destination")
        #expect(fixture.writtenKeys.count == writesAfterRecovery)
        #expect(fixture.synchronizations == syncsAfterRecovery)
    }

    @Test @MainActor
    func anotherDestinationOwnerIsLeftUntouched() {
        let fixture = Fixture(); defer { fixture.cleanup() }
        fixture.installLegacyJournal()
        for key in ["location", "location-screenshot", "location-screenrecording"] { fixture.system[key] = "/other-app" }
        let other = fixture.system
        fixture.inbox.restore()
        #expect(NSDictionary(dictionary: fixture.system).isEqual(to: other))
        #expect(fixture.writtenKeys.isEmpty)
        #expect(fixture.synchronizations == 0)
        #expect(fixture.defaults.dictionary(forKey: fixture.snapshotKey) == nil)
    }

    @Test @MainActor
    func partialDestinationChangeDoesNotRestoreSharedSettings() {
        let fixture = Fixture(); defer { fixture.cleanup() }
        fixture.installLegacyJournal()
        fixture.system["location-screenshot"] = "/other-app"
        fixture.inbox.restore()
        #expect(fixture.system["location-screenshot"] as? String == "/other-app")
        #expect(fixture.system["show-thumbnail"] as? Bool == false)
        #expect(fixture.system["target"] as? String == "file")
        #expect(fixture.system["location"] as? String == "/original")
        #expect(fixture.system["location-screenrecording"] == nil)
        #expect(Set(fixture.writtenKeys) == Set(["location", "location-screenrecording"]))
        #expect(fixture.defaults.dictionary(forKey: fixture.snapshotKey) == nil)
    }

    @MainActor private final class Fixture {
        let name = "Pastes-InboxTests-\(UUID())"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Pastes-InboxTests-\(UUID())")
        let snapshotKey = "captureInboxSnapshot.v1"
        lazy var defaults = UserDefaults(suiteName: name)!
        var system: [String: Any] = ["location": "/original", "show-thumbnail": true, "target": "clipboard"]
        var writtenKeys: [String] = []
        var synchronizations = 0
        lazy var inbox = makeInbox()
        var legacyValues: [String: Any] {
            ["location": folder.path, "location-screenshot": folder.path,
             "location-screenrecording": folder.path, "target": "file",
             "target-screenshot": "file", "target-screenrecording": "file", "show-thumbnail": false]
        }
        func installLegacyJournal() {
            // Construct the exact old on-disk schema without enabling takeover.
            var snapshot: [String: Any] = [:]
            for key in legacyValues.keys {
                snapshot[key] = ["exists": system[key] != nil, "value": system[key] ?? ""]
            }
            defaults.set(snapshot, forKey: snapshotKey)
            system = legacyValues
        }
        func makeInbox() -> CaptureInbox {
            CaptureInbox(folder: folder, defaults: defaults, read: { [unowned self] in system[$0] },
                write: { [unowned self] key, value in
                    writtenKeys.append(key)
                    system[key] = value
                }, synchronize: { [unowned self] in synchronizations += 1 })
        }
        func cleanup() { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: folder) }
    }
}
