import AppKit
import SQLite3
import Testing
@testable import pastes

@Suite("Pinned image lifecycle", .serialized)
struct CapturePinnedLifecycleTests {
    @Test @MainActor
    func screenshotStaysTransientUntilCloseThenImportsOnceFromItsCurrentPosition() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let data = try png(.red)
        let generation = fixture.board.changeCount
        let panel = try fixture.controller.pinScreenshot(data, origin: offscreenOrigin)
        #expect(panel.isVisible && panel.referenceData == data)
        #expect(fixture.library.items.isEmpty && fixture.store.items.isEmpty)
        #expect(fixture.library.latestArrival == nil && !fixture.controller.enabled)
        panel.setFrameOrigin(CGPoint(x: panel.frame.minX + 80, y: panel.frame.minY - 45))
        let currentImageFrame = panel.frame.insetBy(dx: 12, dy: 12)
        #expect(currentImageFrame != offscreenOrigin)
        panel.closeToShelf()
        #expect(!panel.isVisible && panel.referenceData == nil)
        let item = try #require(fixture.library.items.first)
        #expect(fixture.library.items.count == 1 && fixture.store.items.count == 1)
        #expect(fixture.library.latestArrival?.itemID == item.id)
        #expect(fixture.library.arrivalOrigins[item.id] == currentImageFrame)
        #expect(item.historyID == fixture.store.items.first?.id)
        let arrival = fixture.library.latestArrival
        panel.closeToShelf()
        panel.destroyImage()
        #expect(fixture.library.items.count == 1 && fixture.store.items.count == 1)
        #expect(fixture.library.latestArrival == arrival)
        #expect(fixture.board.changeCount == generation)
        #expect(fixture.board.string(forType: .string) == Fixture.clipboardSentinel)
        #expect(fixture.board.data(forType: .png) == nil)
    }

    @Test @MainActor
    func destroyingTransientScreenshotNeverImportsOrAnnouncesAnArrival() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let generation = fixture.board.changeCount
        let panel = try fixture.controller.pinScreenshot(png(.red), origin: offscreenOrigin)
        panel.destroyImage()
        panel.closeToShelf()
        panel.destroyImage()
        #expect(!panel.isVisible && panel.referenceData == nil)
        #expect(fixture.library.items.isEmpty && fixture.store.items.isEmpty)
        #expect(fixture.library.latestArrival == nil && fixture.library.arrivalOrigins.isEmpty)
        #expect(!fixture.controller.enabled && fixture.board.changeCount == generation)
        #expect(fixture.board.string(forType: .string) == Fixture.clipboardSentinel)
    }

    @Test @MainActor
    func editedScreenshotClosesWithTheLatestPixelsWithoutCopying() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let panel = try fixture.controller.pinScreenshot(png(.red), origin: offscreenOrigin)
        let latest = try png(.blue)
        try fixture.controller.editors.updateReference(data: latest, in: panel)
        #expect(panel.referenceData == latest)
        #expect(fixture.library.items.isEmpty && fixture.store.items.isEmpty)
        let generation = fixture.board.changeCount
        panel.closeToShelf()
        let item = try #require(fixture.library.items.first)
        #expect(fixture.library.items.count == 1 && fixture.store.items.count == 1)
        #expect(fixture.store.items.first?.imageData == latest)
        #expect(try color(Data(contentsOf: fixture.library.url(for: item))).blueComponent > 0.9)
        #expect(fixture.board.changeCount == generation)
    }

    @Test @MainActor
    func menuUsesDistinctCloseAndDestroyAndCopiesTheLatestEditedData() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        var errors: [Error] = []
        var closed: [(Data, CGRect)] = []
        var destroyed = 0, edits = 0
        let editors = CaptureEditors(onSaved: { _ in }, onError: { errors.append($0) }, pasteboard: board)
        defer { editors.closeAll() }
        let original = try png(.red), latest = try png(.blue)
        let panel = try editors.hold(data: original, title: "Lifecycle menu", origin: offscreenOrigin,
            onCloseToShelf: { closed.append(($0, $1)) }, onDestroy: { destroyed += 1 })
        try editors.updateReference(data: latest, in: panel)
        let surface = try #require(panel.contentView as? CaptureReferenceDragView)
        surface.onEdit = { edits += 1 }
        let menu = try contextMenu(for: panel)
        let expectedTitles = [C("关闭", "Close"), C("销毁", "Destroy"),
            C("编辑…", "Edit…"), C("复制图片", "Copy image")]
        #expect(menu.items.count == 4 && Set(menu.items.map(\.title)) == Set(expectedTitles))
        #expect(menu.items.allSatisfy { $0.submenu == nil && !$0.isSeparatorItem })
        #expect(!menu.items.contains { $0.title.contains("实时缩放日志") || $0.title == C("取消固定", "Unpin from screen") })
        try invoke(C("编辑…", "Edit…"), in: menu)
        #expect(edits == 1 && closed.isEmpty && destroyed == 0)
        try invoke(C("复制图片", "Copy image"), in: menu)
        #expect(board.data(forType: .png) == latest)
        panel.setFrameOrigin(CGPoint(x: panel.frame.minX + 42, y: panel.frame.minY + 25))
        let currentFrame = panel.frame.insetBy(dx: 12, dy: 12)
        try invoke(C("关闭", "Close"), in: menu)
        #expect(closed.count == 1 && closed.first?.0 == latest && closed.first?.1 == currentFrame)
        #expect(destroyed == 0 && !panel.isVisible && panel.referenceData == nil)

        let discarded = try editors.hold(data: original, title: "Lifecycle destroy", origin: offscreenOrigin,
            onCloseToShelf: { closed.append(($0, $1)) }, onDestroy: { destroyed += 1 })
        try invoke(C("销毁", "Destroy"), in: contextMenu(for: discarded))
        #expect(destroyed == 1 && closed.count == 1 && !discarded.isVisible)
        #expect(errors.isEmpty)
    }

    @Test @MainActor
    func failedCloseRetainsTheWindowAndLatestDataForAnExplicitRetry() throws {
        var errors: [Error] = []
        var attempts = 0
        var accepted: [(Data, CGRect)] = []
        let editors = CaptureEditors(onSaved: { _ in }, onError: { errors.append($0) })
        defer { editors.closeAll() }
        let latest = try png(.blue)
        let panel = try editors.hold(data: png(.red), title: "Retry close", origin: offscreenOrigin,
            onCloseToShelf: { data, frame in
                attempts += 1
                if attempts == 1 { throw RetryFailure.expected }
                accepted.append((data, frame))
            })
        try editors.updateReference(data: latest, in: panel)
        panel.closeToShelf()
        #expect(attempts == 1 && accepted.isEmpty && errors.count == 1)
        #expect(panel.isVisible && panel.referenceData == latest && panel.contentView != nil)
        panel.setFrameOrigin(CGPoint(x: panel.frame.minX - 25, y: panel.frame.minY + 60))
        let retryFrame = panel.frame.insetBy(dx: 12, dy: 12)
        panel.closeToShelf()
        #expect(attempts == 2 && accepted.count == 1)
        #expect(accepted.first?.0 == latest && accepted.first?.1 == retryFrame)
        #expect(!panel.isVisible && panel.referenceData == nil)
        panel.closeToShelf()
        #expect(attempts == 2)
    }

    @Test @MainActor
    func screenshotCloseRetriesTheCommittedMediaIdentityAfterHistorySnapshotFailure() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let panel = try fixture.controller.pinScreenshot(png(.red), origin: offscreenOrigin)
        try fixture.controller.editors.updateReference(data: png(.blue), in: panel)
        let generation = fixture.board.changeCount
        try fixture.failNewHistorySnapshots()
        panel.closeToShelf()
        let pending = try #require(fixture.library.items.first)
        #expect(fixture.library.items.count == 1 && fixture.store.items.isEmpty)
        #expect(try CaptureLibrary(directory: fixture.library.directory).items == [pending])
        #expect(fixture.controller.errorMessage != nil && panel.isVisible && panel.referenceData != nil)
        #expect(try color(Data(contentsOf: fixture.library.url(for: pending))).blueComponent > 0.9)

        try fixture.restoreHistorySnapshots()
        fixture.controller.errorMessage = nil
        let latest = try png(.green)
        try fixture.controller.editors.updateReference(data: latest, in: panel)
        panel.setFrameOrigin(CGPoint(x: panel.frame.minX + 35, y: panel.frame.minY + 45))
        let retryFrame = panel.frame.insetBy(dx: 12, dy: 12)
        panel.closeToShelf()
        let saved = try #require(fixture.library.items.first)
        #expect(saved.id == pending.id && fixture.library.items.count == 1)
        #expect(fixture.store.items.count == 1 && fixture.controller.errorMessage == nil)
        let history = try #require(fixture.store.items.first { $0.id == saved.historyID })
        #expect(history.imageData == latest)
        #expect(try color(Data(contentsOf: fixture.library.url(for: saved))).greenComponent > 0.9)
        #expect(fixture.library.latestArrival?.itemID == pending.id)
        #expect(fixture.library.arrivalOrigins[pending.id] == retryFrame)
        #expect(!panel.isVisible && panel.referenceData == nil && fixture.board.changeCount == generation)
        panel.closeToShelf()
        #expect(fixture.library.items.count == 1 && fixture.store.items.count == 1)
    }

    @Test @MainActor
    func destroyingAfterHistorySnapshotFailureRemovesThePendingImageWithoutAnotherArrival() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let panel = try fixture.controller.pinScreenshot(png(.red), origin: offscreenOrigin)
        let generation = fixture.board.changeCount
        try fixture.failNewHistorySnapshots()
        panel.closeToShelf()
        let pending = try #require(fixture.library.items.first)
        #expect(panel.isVisible && fixture.controller.errorMessage != nil && fixture.store.items.isEmpty)
        #expect(try CaptureLibrary(directory: fixture.library.directory).items == [pending])
        let failedArrival = fixture.library.latestArrival
        panel.destroyImage()
        panel.closeToShelf()
        #expect(!panel.isVisible && panel.referenceData == nil)
        #expect(!fixture.library.visibleItems.contains { $0.id == pending.id })
        #expect(fixture.library.latestArrival == failedArrival && fixture.store.items.isEmpty)
        #expect(fixture.board.changeCount == generation)
        try fixture.restoreHistorySnapshots()
        #expect(try ClipboardStore(url: fixture.root.appendingPathComponent("history.sqlite")).items.isEmpty)
    }

    @Test @MainActor
    func editedShelfImageRetriesItsOwnCommittedRevisionAfterHistorySnapshotFailure() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let original = try fixture.controller.acceptScreenshot(png(.red), origin: offscreenOrigin, copyToClipboard: false)
        let originalHistory = fixture.store.items
        let arrival = fixture.library.latestArrival
        let panel = try holdShelfItem(original, using: fixture.controller)
        #expect(fixture.library.shelfItems.isEmpty && fixture.library.visibleItems.isEmpty)
        try fixture.controller.editors.updateReference(data: png(.blue), in: panel)
        let generation = fixture.board.changeCount
        try fixture.failNewHistorySnapshots()
        panel.closeToShelf()
        let pending = try #require(fixture.library.items.first)
        #expect(pending.id == original.id && pending.digest != original.digest)
        #expect(try CaptureLibrary(directory: fixture.library.directory).items == [pending])
        #expect(fixture.store.items == originalHistory && fixture.library.latestArrival == arrival)
        #expect(panel.isVisible && fixture.controller.errorMessage != nil)
        #expect(fixture.library.shelfItems.isEmpty && fixture.library.visibleItems.isEmpty)
        #expect(!pending.isHidden && !fixture.library.canUndo)

        try fixture.restoreHistorySnapshots()
        fixture.controller.errorMessage = nil
        let latest = try png(.green)
        try fixture.controller.editors.updateReference(data: latest, in: panel)
        panel.closeToShelf()
        let saved = try #require(fixture.library.items.first)
        #expect(saved.id == original.id && fixture.library.items.count == 1)
        #expect(fixture.store.items.count == 2 && fixture.controller.errorMessage == nil)
        let history = try #require(fixture.store.items.first { $0.id == saved.historyID })
        #expect(history.imageData == latest)
        #expect(try color(Data(contentsOf: fixture.library.url(for: saved))).greenComponent > 0.9)
        #expect(fixture.library.latestArrival?.itemID == original.id)
        #expect(fixture.library.latestArrival?.token != arrival?.token)
        #expect(fixture.library.shelfItems.map(\.id) == [original.id])
        #expect(!panel.isVisible && panel.referenceData == nil && fixture.board.changeCount == generation)
        panel.closeToShelf()
        #expect(fixture.library.items.count == 1 && fixture.store.items.count == 2)
    }

    @Test @MainActor
    func rawClosingTheOwnerCancelsPendingNativeEditingWithoutSavingOrReshowingIt() throws {
        var activeStates: [Bool] = []
        var errors: [Error] = []
        var saved = 0, closedToShelf = 0
        let editors = CaptureEditors(onSaved: { _ in saved += 1 }, onError: { errors.append($0) },
            onReferenceEditingChanged: { activeStates.append($0) })
        defer { editors.closeAll() }
        let panel = try editors.hold(data: png(.red), title: "Pending native editing", origin: offscreenOrigin,
            onCloseToShelf: { _, _ in closedToShelf += 1 })
        // Use the real menu target/action and close synchronously before the
        // deferred screenshot capture starts; no capture permission is needed.
        try invoke(C("编辑…", "Edit…"), in: contextMenu(for: panel))
        #expect(activeStates == [true] && !panel.isVisible)
        panel.close()
        #expect(activeStates == [true, false])
        #expect(panel.referenceData == nil && !panel.isVisible)
        #expect(errors.isEmpty && saved == 0 && closedToShelf == 0)
        editors.closeAll()
        #expect(activeStates == [true, false] && !panel.isVisible)
    }

    @Test @MainActor
    func rawCloseCloseAllAndControllerStopDiscardTransientImagesWithoutImporting() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let data = try png(.red)
        let generation = fixture.board.changeCount
        let raw = try fixture.controller.pinScreenshot(data, origin: offscreenOrigin)
        raw.close()
        raw.closeToShelf()
        let closeAll = try fixture.controller.pinScreenshot(data, origin: offscreenOrigin)
        fixture.controller.editors.closeAll()
        closeAll.closeToShelf()
        let stopped = try fixture.controller.pinScreenshot(data, origin: offscreenOrigin)
        fixture.controller.stop()
        stopped.closeToShelf()
        for panel in [raw, closeAll, stopped] {
            #expect(!panel.isVisible && panel.referenceData == nil)
        }
        #expect(fixture.library.items.isEmpty && fixture.store.items.isEmpty)
        #expect(fixture.library.latestArrival == nil && fixture.board.changeCount == generation)
    }

    @Test @MainActor
    func closingAnUneditedShelfImageReturnsItsIdentityWithoutDuplicatingHistory() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let item = try fixture.controller.acceptScreenshot(png(.red), origin: offscreenOrigin, copyToClipboard: false)
        let arrival = fixture.library.latestArrival
        let historyIDs = fixture.store.items.map(\.id)
        let generation = fixture.board.changeCount
        let panel = try holdShelfItem(item, using: fixture.controller)
        #expect(fixture.library.latestArrival == arrival)
        #expect(fixture.library.shelfItems.isEmpty && fixture.library.visibleItems.isEmpty)
        #expect(fixture.library.items == [item] && !fixture.library.canUndo)
        #expect(try CaptureLibrary(directory: fixture.library.directory).visibleItems == [item])
        panel.setFrameOrigin(CGPoint(x: -10000, y: -9800))
        let currentFrame = panel.frame.insetBy(dx: 12, dy: 12)
        panel.closeToShelf()
        #expect(fixture.library.items.map(\.id) == [item.id])
        #expect(fixture.library.shelfItems.map(\.id) == [item.id])
        #expect(fixture.store.items.map(\.id) == historyIDs)
        #expect(fixture.library.latestArrival?.itemID == item.id)
        #expect(fixture.library.latestArrival?.token != arrival?.token)
        #expect(fixture.library.arrivalOrigins[item.id] == currentFrame)
        let returned = fixture.library.latestArrival
        panel.closeToShelf()
        #expect(fixture.library.latestArrival == returned && fixture.board.changeCount == generation)
    }

    @Test @MainActor
    func destroyingAShelfImageRemovesItFromTheShelfWithoutAnArrivalOrHistoryDeletion() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let item = try fixture.controller.acceptScreenshot(png(.red), origin: offscreenOrigin, copyToClipboard: false)
        let arrival = fixture.library.latestArrival
        let historyIDs = fixture.store.items.map(\.id)
        let generation = fixture.board.changeCount
        let panel = try holdShelfItem(item, using: fixture.controller)
        #expect(fixture.library.shelfItems.isEmpty)
        panel.destroyImage()
        panel.closeToShelf()
        #expect(!panel.isVisible && panel.referenceData == nil)
        #expect(!fixture.library.visibleItems.contains { $0.id == item.id })
        #expect(fixture.library.shelfItems.isEmpty)
        #expect(fixture.library.items.first?.isHidden == true)
        #expect(try CaptureLibrary(directory: fixture.library.directory).visibleItems.isEmpty)
        #expect(fixture.library.latestArrival == arrival)
        #expect(fixture.store.items.map(\.id) == historyIDs)
        #expect(fixture.board.changeCount == generation)
    }

    @Test @MainActor
    func closingAnEditedShelfImageUpdatesTheExistingEntryWithTheLatestPixels() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let item = try fixture.controller.acceptScreenshot(png(.red), origin: offscreenOrigin, copyToClipboard: false)
        let panel = try holdShelfItem(item, using: fixture.controller)
        let latest = try png(.blue)
        try fixture.controller.editors.updateReference(data: latest, in: panel)
        let generation = fixture.board.changeCount
        panel.closeToShelf()
        let updated = try #require(fixture.library.items.first)
        #expect(fixture.library.items.count == 1 && updated.id == item.id)
        #expect(fixture.library.shelfItems.map(\.id) == [item.id])
        #expect(updated.digest != item.digest && fixture.store.items.count == 2)
        let history = try #require(fixture.store.items.first { $0.id == updated.historyID })
        #expect(history.imageData == latest)
        #expect(try color(Data(contentsOf: fixture.library.url(for: updated))).blueComponent > 0.9)
        #expect(fixture.library.latestArrival?.itemID == item.id && fixture.board.changeCount == generation)
    }

    @Test @MainActor
    func repeatedFloatDoesNotCreateAnotherOwnerForAnImageTakenFromTheShelf() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let item = try fixture.controller.acceptScreenshot(png(.red), origin: offscreenOrigin, copyToClipboard: false)
        let panel = try holdShelfItem(item, using: fixture.controller)
        let windows = Set(NSApplication.shared.windows.map(\.windowNumber))
        fixture.controller.hold(item)
        #expect(Set(NSApplication.shared.windows.map(\.windowNumber)) == windows)
        #expect(panel.isVisible && !panel.isReferenceFinished)
        #expect(fixture.library.shelfItems.isEmpty && fixture.library.visibleItems.isEmpty)
        panel.closeToShelf()
        #expect(fixture.library.shelfItems.map(\.id) == [item.id])
        #expect(fixture.library.items.count == 1 && fixture.store.items.count == 1)
    }

    @Test @MainActor
    func acceptingTheSameImageWhileItsOriginalIsFloatingKeepsAnIndependentShelfCopy() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let data = try png(.red)
        let original = try fixture.controller.acceptScreenshot(data, origin: offscreenOrigin, copyToClipboard: false)
        let panel = try holdShelfItem(original, using: fixture.controller)
        let heldData = try #require(panel.referenceData)
        let copy = try fixture.controller.acceptScreenshot(data, origin: offscreenOrigin, copyToClipboard: false)
        #expect(copy.id != original.id && copy.digest == original.digest)
        #expect(fixture.library.items.first { $0.id == original.id } == original)
        #expect(fixture.library.shelfItems.map(\.id) == [copy.id])
        #expect(panel.isVisible && panel.referenceData == heldData)
        // A regular import must deduplicate against the shelf copy, never the
        // older matching identity that is still owned by the floating window.
        let imported = try fixture.library.importImage(data, title: "Same image imported again")
        #expect(imported.id == copy.id && fixture.library.items.count == 2)
        #expect(fixture.library.items.first { $0.id == original.id } == original)
        let history = fixture.store.items
        let arrival = fixture.library.latestArrival
        let generation = fixture.board.changeCount
        panel.destroyImage()
        #expect(!panel.isVisible && panel.referenceData == nil)
        #expect(fixture.library.items.first { $0.id == original.id }?.isHidden == true)
        #expect(fixture.library.shelfItems.map(\.id) == [copy.id])
        #expect(try Data(contentsOf: fixture.library.url(for: imported)) == Data(contentsOf: fixture.library.url(for: original)))
        #expect(fixture.store.items == history && history.count == 2)
        #expect(fixture.library.latestArrival == arrival && fixture.board.changeCount == generation)
        #expect(try CaptureLibrary(directory: fixture.library.directory).shelfItems.map(\.id) == [copy.id])
    }

    @Test @MainActor
    func failedShelfReturnKeepsTheImageTakenUntilItsManifestCanBeSaved() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let item = try fixture.controller.acceptScreenshot(png(.red), origin: offscreenOrigin, copyToClipboard: false)
        let arrival = fixture.library.latestArrival
        let panel = try holdShelfItem(item, using: fixture.controller)
        let manifest = fixture.library.directory.appendingPathComponent("library.json")
        let backup = fixture.library.directory.appendingPathComponent("library-backup.json")
        try FileManager.default.moveItem(at: manifest, to: backup)
        defer {
            if FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.removeItem(at: manifest)
                try? FileManager.default.moveItem(at: backup, to: manifest)
            }
        }
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        panel.closeToShelf()
        #expect(panel.isVisible && panel.referenceData != nil)
        #expect(fixture.controller.errorMessage != nil)
        #expect(fixture.library.shelfItems.isEmpty && fixture.library.visibleItems.isEmpty)
        #expect(fixture.library.items == [item] && fixture.library.latestArrival == arrival)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.moveItem(at: backup, to: manifest)
        fixture.controller.errorMessage = nil
        panel.closeToShelf()
        #expect(!panel.isVisible && panel.referenceData == nil)
        #expect(fixture.controller.errorMessage == nil)
        #expect(fixture.library.shelfItems.map(\.id) == [item.id])
        #expect(fixture.library.latestArrival?.token != arrival?.token)
    }

    @Test @MainActor
    func rawCloseCloseAllAndStopRestoreExistingShelfImagesWithoutNewArrivals() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let item = try fixture.controller.acceptScreenshot(png(.red), origin: offscreenOrigin, copyToClipboard: false)
        let arrival = fixture.library.latestArrival
        let history = fixture.store.items
        let generation = fixture.board.changeCount
        for teardown in 0..<3 {
            let panel = try holdShelfItem(item, using: fixture.controller)
            #expect(fixture.library.shelfItems.isEmpty && fixture.library.visibleItems.isEmpty)
            switch teardown {
            case 0: panel.close()
            case 1: fixture.controller.editors.closeAll()
            default: fixture.controller.stop()
            }
            #expect(!panel.isVisible && panel.referenceData == nil)
            #expect(fixture.library.shelfItems.map(\.id) == [item.id])
            #expect(fixture.library.items == [item] && !fixture.library.canUndo)
            #expect(fixture.library.latestArrival == arrival)
            panel.closeToShelf()
            #expect(fixture.library.latestArrival == arrival)
        }
        #expect(fixture.store.items == history && fixture.board.changeCount == generation)
        #expect(try CaptureLibrary(directory: fixture.library.directory).visibleItems == [item])
    }

    @Test(arguments: [false, true]) @MainActor
    func shelfRetentionAndCleanupPreserveTakenImagesAndPrioritizeTheirReturn(includingPins: Bool) throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let original = try fixture.controller.acceptScreenshot(png(.red), origin: offscreenOrigin, copyToClipboard: false)
        if includingPins { try fixture.library.togglePin(original.id) }
        let taken = try #require(fixture.library.items.first { $0.id == original.id })
        let panel = try holdShelfItem(taken, using: fixture.controller)
        try fixture.library.setMaximumItems(1, includingPins: includingPins)
        let older = try fixture.controller.acceptScreenshot(png(.blue), origin: offscreenOrigin, copyToClipboard: false)
        let newer = try fixture.controller.acceptScreenshot(png(.green), origin: offscreenOrigin, copyToClipboard: false)
        #expect(fixture.library.shelfItems.map(\.id) == [newer.id])
        #expect(fixture.library.items.first { $0.id == taken.id }?.isHidden == false)
        #expect(fixture.library.items.first { $0.id == older.id }?.isHidden == true)
        let heldFile = fixture.library.url(for: taken)
        try fixture.library.purgeHidden()
        #expect(FileManager.default.fileExists(atPath: heldFile.path))
        #expect(fixture.library.items.contains { $0.id == taken.id && !$0.isHidden })
        #expect(!fixture.library.items.contains { $0.id == older.id })
        #expect(fixture.library.shelfItems.map(\.id) == [newer.id])
        panel.closeToShelf()
        #expect(!panel.isVisible && fixture.controller.errorMessage == nil)
        #expect(fixture.library.shelfItems.map(\.id) == [taken.id])
        #expect(fixture.library.items.first { $0.id == newer.id }?.isHidden == true)
        #expect(fixture.library.latestArrival?.itemID == taken.id)
        #expect(FileManager.default.fileExists(atPath: heldFile.path))
    }

    @MainActor private func holdShelfItem(_ item: CaptureItem, using controller: CaptureController) throws -> CaptureReferencePanel {
        let previous = Set(NSApplication.shared.windows.map(\.windowNumber))
        controller.hold(item)
        let panel = try #require(NSApplication.shared.windows.compactMap { $0 as? CaptureReferencePanel }
            .first { !previous.contains($0.windowNumber) && $0.title.hasSuffix(" · " + item.title) })
        panel.setFrameOrigin(offscreenOrigin.origin)
        return panel
    }

    @MainActor private func contextMenu(for panel: CaptureReferencePanel) throws -> NSMenu {
        let surface = try #require(panel.contentView as? CaptureReferenceDragView)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: CGPoint(x: 40, y: 40),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        return try #require(surface.menu(for: event))
    }

    @MainActor private func invoke(_ title: String, in menu: NSMenu) throws {
        let item = try #require(menu.items.first { $0.title == title })
        let action = try #require(item.action)
        #expect(NSApplication.shared.sendAction(action, to: item.target, from: item))
    }

    private var offscreenOrigin: CGRect { CGRect(x: -10000, y: -10000, width: 300, height: 180) }
    private enum RetryFailure: Error { case expected }

    @MainActor private func color(_ data: Data) throws -> NSColor {
        let bitmap = try #require(NSBitmapImageRep(data: data))
        return try #require(bitmap.colorAt(x: 4, y: 4)?.usingColorSpace(.deviceRGB))
    }

    @MainActor private func png(_ color: NSColor) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 12,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let rgb = try #require(color.usingColorSpace(.deviceRGB))
        let pixels = try #require(bitmap.bitmapData)
        for y in 0..<12 { for x in 0..<20 {
            let offset = y * bitmap.bytesPerRow + x * 4
            pixels[offset] = UInt8((rgb.redComponent * 255).rounded())
            pixels[offset + 1] = UInt8((rgb.greenComponent * 255).rounded())
            pixels[offset + 2] = UInt8((rgb.blueComponent * 255).rounded())
            pixels[offset + 3] = 255
        } }
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @MainActor private final class Fixture {
        static let clipboardSentinel = "Keep the existing clipboard"
        let root: URL
        let domain: String
        let defaults: UserDefaults
        let board: NSPasteboard
        let store: ClipboardStore
        let library: CaptureLibrary
        let controller: CaptureController

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("Pastes-PinnedLifecycle-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            domain = "Pastes-PinnedLifecycle-\(UUID())"
            defaults = try #require(UserDefaults(suiteName: domain))
            board = NSPasteboard.withUniqueName()
            board.setString(Self.clipboardSentinel, forType: .string)
            store = try ClipboardStore(url: root.appendingPathComponent("history.sqlite"))
            library = try CaptureLibrary(directory: root.appendingPathComponent("Library"))
            let session = ClipboardSession(store: store, pasteboard: board, defaults: defaults)
            controller = CaptureController(library: library, session: session, defaults: defaults)
        }

        func failNewHistorySnapshots() throws {
            // The insert and media update succeed, but the store's subsequent
            // snapshot rejects this TEXT timestamp and rolls SQLite back.
            // This trigger exists only in the fixture's temporary database.
            try historySQL("""
                CREATE TRIGGER fail_history_snapshot AFTER INSERT ON clipboard_items
                BEGIN
                    UPDATE clipboard_items SET timestamp = 'invalid' WHERE id = NEW.id;
                END
                """)
        }

        func restoreHistorySnapshots() throws {
            try historySQL("DROP TRIGGER fail_history_snapshot")
        }

        private func historySQL(_ sql: String) throws {
            var connection: OpaquePointer?
            let status = sqlite3_open(root.appendingPathComponent("history.sqlite").path, &connection)
            defer { if let connection { sqlite3_close_v2(connection) } }
            try #require(status == SQLITE_OK)
            let database = try #require(connection)
            try #require(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        }

        func cleanup() {
            controller.stop()
            board.releaseGlobally()
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
