import AppKit
import Testing
@testable import pastes

@Suite("Capture preferences")
struct CapturePreferencesTests {
    @Test @MainActor
    func savedScreenshotOnlyWritesFileRegardlessOfLegacyPolicyOrShelfState() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let domain = "Pastes-ScreenshotPolicy-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString("Existing clipboard", forType: .string)
        let generation = board.changeCount
        let store = try ClipboardStore(url: root.appendingPathComponent("history.sqlite"))
        let session = ClipboardSession(store: store, pasteboard: board, defaults: defaults)
        let library = try CaptureLibrary(directory: root.appendingPathComponent("Library"))
        let data = try png(.red)
        let origin = CGRect(x: -10000, y: -10000, width: 300, height: 200)
        let destination = root.appendingPathComponent("Saved screenshot.png")
        for shelfEnabled in [false, true] {
            defaults.set(shelfEnabled, forKey: "captureShelfEnabled")
            for legacyValue in [nil, false, true] as [Bool?] {
                if let legacyValue { defaults.set(legacyValue, forKey: "captureSaveScreenshotToShelf") }
                else { defaults.removeObject(forKey: "captureSaveScreenshotToShelf") }
                let controller = CaptureController(library: library, session: session, defaults: defaults)
                try controller.screenshot.savePNG(data, origin: origin, to: destination)
                #expect(try Data(contentsOf: destination) == data)
                #expect(controller.enabled == shelfEnabled && !controller.lineRevealed)
                #expect(library.items.isEmpty && store.items.isEmpty && library.latestArrival == nil)
                #expect(library.arrivalOrigins.isEmpty && library.arrivalTokens.isEmpty)
                #expect(board.changeCount == generation)
            }
        }
        #expect(board.string(forType: .string) == "Existing clipboard")
        #expect(board.data(forType: .png) == nil)
    }

    @Test @MainActor
    func legacyPinPolicyNeverImportsOnPin() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let domain = "Pastes-LegacyPinPolicy-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString("Existing clipboard", forType: .string)
        let generation = board.changeCount
        let store = try ClipboardStore(url: root.appendingPathComponent("history.sqlite"))
        let session = ClipboardSession(store: store, pasteboard: board, defaults: defaults)
        let library = try CaptureLibrary(directory: root.appendingPathComponent("Library"))
        let data = try png(.red)
        let origin = CGRect(x: -10000, y: -10000, width: 300, height: 200)
        for legacyValue in [true, false] {
            defaults.set(legacyValue, forKey: "capturePinScreenshotToShelf")
            let reopened = CaptureController(library: library, session: session, defaults: defaults)
            defer { reopened.editors.closeAll() }
            let panel = try reopened.pinScreenshot(data, origin: origin)
            #expect(panel.isVisible)
            #expect(!reopened.enabled && library.items.isEmpty && store.items.isEmpty)
            #expect(library.latestArrival == nil)
            panel.destroyImage()
        }
        #expect(board.changeCount == generation)
        #expect(board.string(forType: .string) == "Existing clipboard")
        #expect(board.data(forType: .png) == nil)
    }

    @Test @MainActor
    func historyFilteringIsReversibleAndPreservesPinnedImages() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try ClipboardStore(url: root.appendingPathComponent("history.sqlite"))
        try store.addText("Text", limit: 0)
        let imageID = try store.addImage(png(.red), limit: 0)
        try store.togglePin(id: imageID)
        let original = store.items
        let hidden = ContentView.historyItems(original, shelfEnabled: true, hideImages: true)
        #expect(hidden.count == 1)
        #expect(hidden.first?.content == "Text")
        #expect(ContentView.historyItems(original, shelfEnabled: false, hideImages: true).count == 2)
        #expect(ContentView.historyItems(original, shelfEnabled: true, hideImages: false).count == 2)
        #expect(store.items.count == 2)
        #expect(store.items.first(where: { $0.id == imageID })?.isPinned == true)
    }

    @Test @MainActor
    func limitKeepsNewestAndPinsAndPersistsWithoutDeletingFiles() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try CaptureLibrary(directory: root)
        let first = try library.importImage(png(.red), title: "Pinned")
        try library.togglePin(first.id)
        let second = try library.importImage(png(.green), title: "Old")
        let third = try library.importImage(png(.blue), title: "New")
        try library.setMaximumItems(1)
        #expect(Set(library.visibleItems.map(\.id)) == Set([first.id, third.id]))
        #expect(FileManager.default.fileExists(atPath: library.url(for: second).path))
        #expect(try CaptureLibrary(directory: root).items == library.items)
        let copy = try library.importImage(png(.blue), title: "Copy", forceNew: true)
        #expect(Set(library.visibleItems.map(\.id)) == Set([first.id, copy.id]))
        try library.togglePin(first.id)
        #expect(library.visibleItems.map(\.id) == [copy.id])
        try library.setMaximumItems(0)
        _ = try library.importImage(png(.red), title: "Return")
        _ = try library.importImage(png(.green), title: "Return")
        #expect(library.visibleItems.count == 3)
    }

    @Test @MainActor
    func undoAndDuplicateImportRespectLimit() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try CaptureLibrary(directory: root)
        try library.setMaximumItems(1)
        let first = try library.importImage(png(.red), title: "First")
        try library.remove(first.id)
        _ = try library.importImage(png(.blue), title: "Second")
        try library.undo()
        #expect(library.visibleItems.map(\.id) == [first.id])
        _ = try library.importImage(png(.blue), title: "Second again")
        #expect(library.visibleItems.count == 1)
        #expect(library.visibleItems.first?.id != first.id)
    }

    @Test @MainActor
    func controllerRestoresSettingsAndFailedLimitDoesNotPublish() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let domain = "Pastes-Preferences-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = try ClipboardStore(url: root.appendingPathComponent("history.sqlite"))
        let session = ClipboardSession(store: store, pasteboard: NSPasteboard.withUniqueName(), defaults: defaults)
        let library = try CaptureLibrary(directory: root.appendingPathComponent("Library"))
        let controller = CaptureController(library: library, session: session, defaults: defaults)
        #expect(controller.maximumItems == 20)
        #expect(controller.hideImagesInHistory)
        controller.setMaximumItems(50)
        controller.setHideImagesInHistory(false)
        let reopened = CaptureController(library: library, session: session, defaults: defaults)
        #expect(reopened.maximumItems == 50)
        #expect(!reopened.hideImagesInHistory)
        let manifest = library.directory.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: true)
        controller.setMaximumItems(10)
        #expect(controller.maximumItems == 50)
        #expect(library.maximumItems == 50)
        #expect(defaults.integer(forKey: "captureMaximumItems") == 50)
        #expect(controller.errorMessage != nil)
    }

    @Test @MainActor
    func customLimitAboveEightSurvivesRestartAndAppliesExactly() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let domain = "Pastes-CustomRetention-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let store = try ClipboardStore(url: root.appendingPathComponent("history.sqlite"))
        let session = ClipboardSession(store: store, pasteboard: board, defaults: defaults)
        let library = try CaptureLibrary(directory: root.appendingPathComponent("Library"))
        let controller = CaptureController(library: library, session: session, defaults: defaults)
        controller.selectCustomLimit()
        #expect(controller.maximumItems == 20) // Selecting Custom alone cannot trim the shelf.
        controller.setCustomMaximumItems(37)
        let bytes = try png(.red)
        for index in 0..<45 { _ = try library.importImage(bytes, title: "Image \(index)", forceNew: true) }
        #expect(library.visibleItems.count == 37)
        let reopenedLibrary = try CaptureLibrary(directory: library.directory)
        let reopened = CaptureController(library: reopenedLibrary, session: session, defaults: defaults)
        #expect(reopened.maximumItems == 37)
        #expect(reopened.usesCustomLimit)
        #expect(reopenedLibrary.visibleItems.count == 37)
        reopened.setCustomMaximumItems(13)
        #expect(reopenedLibrary.visibleItems.count == 13)
        reopened.setCustomMaximumItems(0)
        #expect(reopened.maximumItems == 13)
        reopened.setCustomMaximumItems(250)
        #expect(reopened.maximumItems == 250)
        reopened.setMaximumItems(20)
        #expect(!reopened.usesCustomLimit)
    }

    @Test func customInputRejectsInvalidOrOverflowingValues() {
        #expect(CaptureRetentionInput.parse(" 37 ") == 37)
        #expect(CaptureRetentionInput.parse("250") == 250)
        for input in ["", "0", "-1", "2.5", "abc", "1e3", "999999999999999999999999999"] {
            #expect(CaptureRetentionInput.parse(input) == nil)
        }
    }

    @Test func everyRetainedImageCanBeReachedByPagingAtDifferentScreenWidths() {
        for width: CGFloat in [800, 1440, 2560] {
            for count in [8, 10, 37, 250] {
                let overflow = CaptureLineLayout.overflow(itemCount: count, width: width)
                var scroll: CGFloat = 0
                var reached = Set<Int>()
                while true {
                    for index in 0..<count {
                        let x = CaptureLineLayout.cardX(index: index, itemCount: count, width: width, scroll: scroll)
                        if x >= 75 && x <= width - 75 { reached.insert(index) }
                    }
                    if scroll == overflow { break }
                    scroll = CaptureLineLayout.clampedScroll(scroll + max(CaptureLineLayout.spacing, width - 200), overflow: overflow)
                }
                #expect(reached.count == count)
                #expect(CaptureLineLayout.clampedScroll(scroll - 100_000, overflow: overflow) == 0)
            }
        }
    }

    @Test @MainActor
    func adaptiveCapacityFollowsScreenAndCountsPinsWithoutLosingNumericPreference() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let domain = "Pastes-Adaptive-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let store = try ClipboardStore(url: root.appendingPathComponent("history.sqlite"))
        let session = ClipboardSession(store: store, pasteboard: board, defaults: defaults)
        let library = try CaptureLibrary(directory: root.appendingPathComponent("Library"))
        let controller = CaptureController(library: library, session: session, defaults: defaults)
        controller.setCustomMaximumItems(37)
        let bytes = try png(.red)
        let pinned = try library.importImage(bytes, title: "Pinned", forceNew: true)
        try library.togglePin(pinned.id)
        for index in 0..<12 { _ = try library.importImage(bytes, title: "\(index)", forceNew: true) }
        controller.updateShelfWidth(1440)
        controller.setAdaptiveRetention()
        #expect(controller.adaptiveCapacity == 8)
        #expect(library.visibleItems.count == 8)
        #expect(library.visibleItems.contains(where: { $0.id == pinned.id }))
        controller.updateShelfWidth(800)
        #expect(library.visibleItems.count == 4)
        #expect(controller.maximumItems == 37)
        let reopened = CaptureController(library: library, session: session, defaults: defaults)
        #expect(reopened.adaptiveRetention)
        #expect(reopened.maximumItems == 37)
        reopened.selectCustomLimit()
        #expect(!reopened.adaptiveRetention)
        #expect(library.maximumItems == 37)
        #expect(!defaults.bool(forKey: "captureAdaptiveRetention"))
    }

    @Test @MainActor
    func adaptivePinsCanExceedScreenWithoutBeingRemoved() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try CaptureLibrary(directory: root)
        let bytes = try png(.red)
        for index in 0..<5 {
            let item = try library.importImage(bytes, title: "\(index)", forceNew: true)
            try library.togglePin(item.id)
        }
        try library.setMaximumItems(4, includingPins: true)
        _ = try library.importImage(bytes, title: "Overflow", forceNew: true)
        #expect(library.visibleItems.count == 5)
        #expect(library.visibleItems.allSatisfy { $0.isPinned })
    }

    @Test func adaptiveLayoutFillsWidthWithoutOverflow() {
        for width: CGFloat in [800, 1440, 1920, 2560] {
            let count = CaptureLineLayout.adaptiveCapacity(width: width)
            #expect(CaptureLineLayout.overflow(itemCount: count, width: width) == 0)
            #expect(CaptureLineLayout.overflow(itemCount: count + 1, width: width) > 0)
            #expect(CaptureLineLayout.adaptiveCardX(index: 0, itemCount: count, width: width) == 100)
            #expect(CaptureLineLayout.adaptiveCardX(index: count - 1, itemCount: count, width: width) == width - 100)
        }
        #expect(CaptureLineLayout.adaptiveCardX(index: 0, itemCount: 1, width: 1440) == 720)
    }

    @Test func sparseAdaptiveRowsStayTogetherAtTheScreenCenter() {
        for width: CGFloat in [800, 1440, 1920, 2560] {
            let capacity = CaptureLineLayout.adaptiveCapacity(width: width)
            for count in 2..<capacity {
                let positions = (0..<count).map {
                    CaptureLineLayout.adaptiveCardX(index: $0, itemCount: count, width: width)
                }
                #expect(abs((positions[0] + positions[count - 1]) / 2 - width / 2) < 0.001)
                #expect(positions[0] > 100 && positions[count - 1] < width - 100)
                for index in 1..<count {
                    #expect(abs(positions[index] - positions[index - 1] - CaptureLineLayout.spacing) < 0.001)
                }
            }
        }
        #expect(CaptureLineLayout.adaptiveCardX(index: 0, itemCount: 2, width: 1440) == 633)
        #expect(CaptureLineLayout.adaptiveCardX(index: 1, itemCount: 2, width: 1440) == 807)
        #expect(CaptureLineLayout.adaptiveCardX(index: 1, itemCount: 3, width: 1440) == 720)
    }

    @Test @MainActor
    func directionalRemovalUsesPinnedVisualOrderAndUndoRestoresWholeBatch() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try CaptureLibrary(directory: root)
        let bytes = try png(.red)
        var imported: [CaptureItem] = []
        for index in 0..<6 { imported.append(try library.importImage(bytes, title: "\(index)", forceNew: true)) }
        try library.togglePin(imported[5].id)
        let ordered = library.shelfItems
        #expect(ordered.first?.id == imported[5].id)
        let anchor = ordered[3]
        let left = library.removalIDs(relativeTo: anchor.id, side: .left)
        let right = library.removalIDs(relativeTo: anchor.id, side: .right)
        #expect(left == Array(ordered.prefix(3)).map(\.id))
        #expect(right == Array(ordered.dropFirst(4)).map(\.id))
        #expect(!left.contains(anchor.id) && !right.contains(anchor.id))
        try library.remove(ids: left)
        #expect(Set(library.visibleItems.map(\.id)) == Set(ordered.dropFirst(3).map(\.id)))
        for item in ordered { #expect(FileManager.default.fileExists(atPath: library.url(for: item).path)) }
        try library.undo()
        #expect(Set(library.visibleItems.map(\.id)) == Set(ordered.map(\.id)))
        #expect(!library.canUndo)
        #expect(library.visibleItems.first(where: { $0.id == imported[5].id })?.isPinned == true)
        #expect(library.removalIDs(relativeTo: library.shelfItems[0].id, side: .left).isEmpty)
        #expect(library.removalIDs(relativeTo: UUID(), side: .right).isEmpty)
        let rightNow = library.removalIDs(relativeTo: anchor.id, side: .right)
        try library.remove(ids: rightNow)
        #expect(library.visibleItems.contains { $0.id == anchor.id })
        #expect(library.visibleItems.allSatisfy { !rightNow.contains($0.id) })
    }

    @Test @MainActor
    func batchRemovalFailureIsAtomicAndDoesNotOfferUndo() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try CaptureLibrary(directory: root)
        let bytes = try png(.red)
        for index in 0..<3 { _ = try library.importImage(bytes, title: "\(index)", forceNew: true) }
        let before = library.items
        let manifest = root.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try library.remove(ids: before.map(\.id)) }
        #expect(library.items == before)
        #expect(!library.canUndo)
    }

    @Test @MainActor
    func floatingImageFitsItsAspectRatioWithoutWindowPadding() {
        let portrait = CaptureEditors.referenceSize(image: CGSize(width: 900, height: 1200))
        #expect(portrait == CGSize(width: 450, height: 600))
        let landscape = CaptureEditors.referenceSize(image: CGSize(width: 1440, height: 900))
        #expect(landscape == CGSize(width: 720, height: 450))
    }

    @Test @MainActor
    func arrivalsCoverNewAndRepeatedImportsButNotHistoryReloadOrPinChanges() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try CaptureLibrary(directory: root)
        let bytes = try png(.red)
        #expect(library.latestArrival == nil)
        let first = try library.importImage(bytes, title: "First")
        let arrival = try #require(library.latestArrival)
        #expect(arrival.itemID == first.id)
        #expect(library.arrivalOrigins[first.id] == nil)
        #expect(library.arrivalTokens[first.id] == arrival.token)
        try library.togglePin(first.id)
        try library.link(first.id, historyID: UUID())
        #expect(library.latestArrival == arrival)
        let duplicate = try library.importImage(bytes, title: "Copied again")
        #expect(duplicate.id == first.id)
        #expect(library.latestArrival?.token != arrival.token)
        let secondToken = library.latestArrival?.token
        library.animateArrival(first.id)
        #expect(library.latestArrival?.token != secondToken)
        let reopened = try CaptureLibrary(directory: root)
        #expect(reopened.latestArrival == nil)
        #expect(reopened.arrivalTokens.isEmpty)
        #expect(reopened.visibleItems.count == 1)
    }

    @Test @MainActor
    func failedOrImmediatelyEvictedImportsNeverAnimate() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try CaptureLibrary(directory: root)
        let bytes = try png(.red)
        let pinned = try library.importImage(bytes, title: "Pinned")
        try library.togglePin(pinned.id)
        try library.setMaximumItems(1, includingPins: true)
        let previous = library.latestArrival
        let evicted = try library.importImage(bytes, title: "No slot", forceNew: true)
        #expect(!library.visibleItems.contains { $0.id == evicted.id })
        #expect(library.latestArrival == previous)
        let manifest = root.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try library.importImage(bytes, title: "Failed", forceNew: true) }
        #expect(library.latestArrival == previous)
    }

    @Test func hangingWaitsForRevealAndThumbnailAndDoesNotReplayWhenReopened() {
        let token = UUID()
        var request = CaptureHangRequest(token: token, revealed: false, imageReady: false)
        #expect(!request.shouldAnimate(after: nil))
        request.imageReady = true
        #expect(!request.shouldAnimate(after: nil))
        request.revealed = true
        #expect(request.shouldAnimate(after: nil))
        #expect(!request.shouldAnimate(after: token))
        request.revealed = false
        request.revealed = true
        #expect(!request.shouldAnimate(after: token))
        request.token = UUID()
        #expect(request.shouldAnimate(after: token))
        request.token = nil
        #expect(!request.shouldAnimate(after: nil))
    }

    @Test @MainActor
    func arrivalRetainsSourceCoordinatesAndDoesNotPersistThem() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try CaptureLibrary(directory: root)
        let origin = CGRect(x: -800, y: 300, width: 400, height: 300)
        let bytes = try png(.red)
        let item = try library.importImage(bytes, title: "Copied", origin: origin)
        #expect(library.arrivalOrigins[item.id] == origin)
        try library.togglePin(item.id)
        #expect(library.arrivalOrigins[item.id] == origin)
        library.animateArrival(item.id, origin: CGRect(x: 600, y: 400, width: 0, height: 0))
        #expect(library.arrivalOrigins[item.id] == nil)
        let card = CGRect(x: 200, y: 800, width: 140, height: 90)
        library.animateArrival(item.id, origin: card)
        #expect(library.arrivalOrigins[item.id] == card)
        #expect(try CaptureLibrary(directory: root).arrivalOrigins.isEmpty)
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
