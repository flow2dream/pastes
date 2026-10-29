import Foundation
import SQLite3
import Testing
@testable import pastes

@Suite("Clipboard storage")
struct ClipboardStoreTests {
    @Test @MainActor
    func testTextDeduplicatesAfterTrimmingAndPreservesOrReplacesRTF() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite3")
        let store = try ClipboardStore(url: url)
        let originalRTF = Data([0x7B, 0x00, 0xFF, 0x7D])

        try store.addText(" \nalpha\u{0000}beta\t ", rtfData: originalRTF, limit: 0)
        let original = try #require(store.items.first)
        try store.togglePin(id: original.id)
        try store.addText("second", limit: 0)
        try store.addText("alpha\u{0000}beta", limit: 0)

        #expect(store.items.count == 2)
        #expect(store.items.first?.id == original.id)
        #expect(store.items.first?.content == "alpha\u{0000}beta")
        #expect(store.items.first?.rtfData == originalRTF)
        #expect(store.items.first?.isPinned == true)
        #expect(try #require(store.items.first).timestamp >= original.timestamp)

        try store.addText("alpha\u{0000}beta", rtfData: Data(), limit: 0)
        #expect(store.items.first?.rtfData == Data())
        try store.addText(" \t\r\n", limit: 0)
        #expect(store.items.count == 2)
        #expect(store.items.map(\.timestamp) == store.items.map(\.timestamp).sorted(by: >))
        #expect(try ClipboardStore(url: url).items == store.items)
    }

    @Test @MainActor
    func testBinaryImagesAndEmptyBlobsSurviveReopening() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/history.sqlite3")
        let image = Data([0x00, 0xFF, 0x01, 0x80, 0x00])
        var snapshot: [ClipboardItem] = []
        do {
            let store = try ClipboardStore(url: url)
            try store.addImage(image, limit: -1)
            try store.addImage(Data(), limit: -1)
            try store.addText("empty rich text", rtfData: Data(), limit: -1)
            snapshot = store.items
        }

        let reopened = try ClipboardStore(url: url)
        #expect(reopened.items == snapshot)
        #expect(reopened.items.filter(\.isImage).count == 2)
        #expect(reopened.items.contains { $0.isImage && $0.imageData == image })
        #expect(reopened.items.contains { $0.isImage && $0.imageData == Data() })
        #expect(reopened.items.first?.rtfData == Data())
        #expect(reopened.items.first?.imageData == nil)
    }

    @Test @MainActor
    func testPinnedItemsCountTowardLimitAndAreNeverAutomaticallyRemoved() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ClipboardStore(url: directory.appendingPathComponent("history.sqlite3"))
        try store.addText("pinned", limit: 2)
        let pinnedID = try #require(store.items.first).id
        try store.togglePin(id: pinnedID)
        try store.addText("old", limit: 2)
        try store.addText("new", limit: 2)
        #expect(Set(store.items.map(\.content)) == Set(["pinned", "new"]))

        let secondPinnedID = try #require(store.items.first { $0.content == "new" }).id
        try store.togglePin(id: secondPinnedID)
        try store.addImage(Data([1]), limit: 1)
        #expect(store.items.count == 2)
        #expect(store.items.allSatisfy { $0.isPinned })

        try store.togglePin(id: secondPinnedID)
        try store.addText("latest", limit: 2)
        #expect(Set(store.items.map(\.content)) == Set(["pinned", "latest"]))
    }

    @Test @MainActor
    func testClearKeepsPinnedItemsAndDeletePersists() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite3")
        let store = try ClipboardStore(url: url)
        try store.addText("keep", limit: 0)
        let pinnedID = try #require(store.items.first).id
        try store.togglePin(id: pinnedID)
        try store.addText("remove", limit: 0)
        try store.addImage(Data([2]), limit: 0)
        try store.clearUnpinned()
        #expect(store.items.map(\.id) == [pinnedID])
        #expect(try ClipboardStore(url: url).items.map(\.id) == [pinnedID])

        try store.delete(id: pinnedID)
        #expect(store.items.isEmpty)
        #expect(try ClipboardStore(url: url).items.isEmpty)
    }

    @Test @MainActor
    func testFailedPruningRollsBackInsertAndLeavesPublishedItemsUnchanged() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite3")
        let store = try ClipboardStore(url: url)
        try store.addText("original", limit: 1)
        let original = store.items
        var connection: OpaquePointer?
        #expect(sqlite3_open(url.path, &connection) == SQLITE_OK)
        let database = try #require(connection)
        defer { sqlite3_close_v2(database) }
        #expect(sqlite3_exec(database, """
            CREATE TRIGGER block_deletion BEFORE DELETE ON clipboard_items
            BEGIN SELECT RAISE(ABORT, 'Test deletion failure'); END
            """, nil, nil, nil) == SQLITE_OK)

        #expect { try store.addText("must roll back", limit: 1) } throws: { _ in true }
        #expect(store.items == original)
        #expect(try ClipboardStore(url: url).items == original)
    }

    @Test @MainActor
    func testOpeningCorruptDatabaseDoesNotOverwriteIt() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite3")
        let original = Data("This is existing corrupt data, not a SQLite database.\u{0000}".utf8)
        try original.write(to: url)

        #expect { try ClipboardStore(url: url) } throws: { _ in true }
        #expect(try Data(contentsOf: url) == original)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PastesStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
