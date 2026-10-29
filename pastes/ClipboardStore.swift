import Combine
import Foundation
import SQLite3

/// Stores clipboard history at an explicit location, separate from legacy SwiftData files.
@MainActor
final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []

    private let database: SQLiteConnection
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        database = try SQLiteConnection(url: url)
        try transaction {
            try execute("""
                CREATE TABLE IF NOT EXISTS clipboard_items (
                    id TEXT PRIMARY KEY NOT NULL,
                    content TEXT NOT NULL,
                    image_data BLOB,
                    rtf_data BLOB,
                    timestamp REAL NOT NULL,
                    is_pinned INTEGER NOT NULL CHECK (is_pinned IN (0, 1)),
                    is_image INTEGER NOT NULL CHECK (is_image IN (0, 1))
                )
                """)
            try execute("CREATE INDEX IF NOT EXISTS clipboard_items_timestamp ON clipboard_items(timestamp)")
        }
    }

    func addText(_ text: String, rtfData: Data? = nil, limit: Int) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        try transaction {
            try withStatement("""
                UPDATE clipboard_items SET timestamp = ?, rtf_data = COALESCE(?, rtf_data)
                WHERE id = (
                    SELECT id FROM clipboard_items WHERE content = ? AND is_image = 0
                    ORDER BY timestamp DESC, rowid DESC LIMIT 1
                )
                """) { statement in
                try check(sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970))
                try bind(rtfData, to: 2, in: statement)
                try bind(trimmed, to: 3, in: statement)
                try finish(statement)
            }
            if sqlite3_changes(database.handle) == 0 {
                try insert(ClipboardItem(content: trimmed, rtfData: rtfData))
            }
            try enforceLimit(limit)
        }
    }

    func addImage(_ data: Data, limit: Int) throws {
        try transaction {
            try insert(ClipboardItem(content: "[Image]", imageData: data))
            try enforceLimit(limit)
        }
    }

    func togglePin(id: UUID) throws {
        try transaction {
            try withStatement("UPDATE clipboard_items SET is_pinned = 1 - is_pinned WHERE id = ?") { statement in
                try bind(id.uuidString, to: 1, in: statement)
                try finish(statement)
            }
        }
    }

    func delete(id: UUID) throws {
        try transaction {
            try withStatement("DELETE FROM clipboard_items WHERE id = ?") { statement in
                try bind(id.uuidString, to: 1, in: statement)
                try finish(statement)
            }
        }
    }

    func clearUnpinned() throws {
        try transaction {
            try execute("DELETE FROM clipboard_items WHERE is_pinned = 0")
        }
    }

    /// Publish only after all writes and the new snapshot have committed successfully.
    private func transaction(_ changes: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try changes()
            let snapshot = try loadItems()
            try execute("COMMIT")
            items = snapshot
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func insert(_ item: ClipboardItem) throws {
        try withStatement("""
            INSERT INTO clipboard_items (id, content, image_data, rtf_data, timestamp, is_pinned, is_image)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """) { statement in
            try bind(item.id.uuidString, to: 1, in: statement)
            try bind(item.content, to: 2, in: statement)
            try bind(item.imageData, to: 3, in: statement)
            try bind(item.rtfData, to: 4, in: statement)
            try check(sqlite3_bind_double(statement, 5, item.timestamp.timeIntervalSince1970))
            try check(sqlite3_bind_int(statement, 6, item.isPinned ? 1 : 0))
            try check(sqlite3_bind_int(statement, 7, item.isImage ? 1 : 0))
            try finish(statement)
        }
    }

    private func enforceLimit(_ limit: Int) throws {
        guard limit > 0 else { return }
        // Pinned rows count toward the limit, but can never be automatically removed.
        try withStatement("""
            DELETE FROM clipboard_items WHERE id IN (
                SELECT id FROM clipboard_items WHERE is_pinned = 0
                ORDER BY timestamp ASC, rowid ASC
                LIMIT MAX((SELECT COUNT(*) FROM clipboard_items) - ?, 0)
            )
            """) { statement in
            try check(sqlite3_bind_int64(statement, 1, Int64(limit)))
            try finish(statement)
        }
    }

    private func loadItems() throws -> [ClipboardItem] {
        try withStatement("""
            SELECT id, content, image_data, rtf_data, timestamp, is_pinned, is_image
            FROM clipboard_items ORDER BY timestamp DESC, rowid DESC
            """) { statement in
            var result: [ClipboardItem] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else { throw failure(status) }
                guard let id = UUID(uuidString: try string(at: 0, in: statement)),
                      sqlite3_column_type(statement, 4) == SQLITE_FLOAT || sqlite3_column_type(statement, 4) == SQLITE_INTEGER,
                      sqlite3_column_type(statement, 5) == SQLITE_INTEGER,
                      sqlite3_column_type(statement, 6) == SQLITE_INTEGER else {
                    throw ClipboardStoreError.invalidDatabase("Clipboard history contains an invalid record.")
                }
                let timestamp = sqlite3_column_double(statement, 4)
                let isPinned = sqlite3_column_int(statement, 5)
                let isImage = sqlite3_column_int(statement, 6)
                guard timestamp.isFinite, (0...1).contains(isPinned), (0...1).contains(isImage) else {
                    throw ClipboardStoreError.invalidDatabase("Clipboard history contains an invalid record.")
                }
                var item = ClipboardItem(
                    id: id,
                    content: try string(at: 1, in: statement),
                    imageData: try data(at: 2, in: statement),
                    rtfData: try data(at: 3, in: statement),
                    timestamp: Date(timeIntervalSince1970: timestamp),
                    isPinned: isPinned == 1
                )
                item.isImage = isImage == 1
                result.append(item)
            }
        }
    }

    private func bind(_ text: String, to index: Int32, in statement: OpaquePointer) throws {
        guard let count = Int32(exactly: text.utf8.count) else {
            throw ClipboardStoreError.invalidDatabase("Clipboard text is too large to store.")
        }
        // Explicit lengths preserve embedded NUL characters.
        try text.withCString { pointer in
            try check(sqlite3_bind_text(statement, index, pointer, count, Self.transient))
        }
    }

    private func bind(_ data: Data?, to index: Int32, in statement: OpaquePointer) throws {
        guard let data else {
            try check(sqlite3_bind_null(statement, index))
            return
        }
        if data.isEmpty {
            // A zero-length blob is different from SQL NULL.
            try check(sqlite3_bind_zeroblob(statement, index, 0))
            return
        }
        guard let count = Int32(exactly: data.count) else {
            throw ClipboardStoreError.invalidDatabase("Clipboard data is too large to store.")
        }
        try data.withUnsafeBytes { bytes in
            try check(sqlite3_bind_blob(statement, index, bytes.baseAddress, count, Self.transient))
        }
    }

    private func string(at index: Int32, in statement: OpaquePointer) throws -> String {
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT,
              let pointer = sqlite3_column_text(statement, index) else {
            throw ClipboardStoreError.invalidDatabase("Clipboard history contains invalid text.")
        }
        let bytes = UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(statement, index)))
        guard let value = String(bytes: bytes, encoding: .utf8) else {
            throw ClipboardStoreError.invalidDatabase("Clipboard history contains invalid UTF-8 text.")
        }
        return value
    }

    private func data(at index: Int32, in statement: OpaquePointer) throws -> Data? {
        let type = sqlite3_column_type(statement, index)
        if type == SQLITE_NULL { return nil }
        guard type == SQLITE_BLOB else {
            throw ClipboardStoreError.invalidDatabase("Clipboard history contains invalid binary data.")
        }
        let count = Int(sqlite3_column_bytes(statement, index))
        if count == 0 { return Data() }
        guard let pointer = sqlite3_column_blob(statement, index) else {
            throw ClipboardStoreError.invalidDatabase("Clipboard history contains unreadable binary data.")
        }
        return Data(bytes: pointer, count: count)
    }

    private func execute(_ sql: String) throws {
        try withStatement(sql) { statement in try finish(statement) }
    }

    private func finish(_ statement: OpaquePointer) throws {
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE else { throw failure(status) }
    }

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(database.handle, sql, -1, &statement, nil)
        defer { if let statement { sqlite3_finalize(statement) } }
        guard status == SQLITE_OK, let statement else { throw failure(status) }
        return try body(statement)
    }

    private func check(_ status: Int32) throws {
        guard status == SQLITE_OK else { throw failure(status) }
    }

    private func failure(_ code: Int32) -> ClipboardStoreError {
        .sqlite(code: code, message: String(cString: sqlite3_errmsg(database.handle)))
    }
}

private final class SQLiteConnection {
    let handle: OpaquePointer

    init(url: URL) throws {
        guard url.isFileURL, !url.path.utf8.contains(0) else {
            throw ClipboardStoreError.invalidDatabase("Clipboard history requires a local file URL.")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var connection: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open clipboard history."
            if let connection { sqlite3_close_v2(connection) }
            throw ClipboardStoreError.sqlite(code: status, message: message)
        }
        handle = connection
        sqlite3_busy_timeout(connection, 5_000)
    }

    deinit {
        sqlite3_close_v2(handle)
    }
}

private enum ClipboardStoreError: LocalizedError {
    case sqlite(code: Int32, message: String)
    case invalidDatabase(String)

    var errorDescription: String? {
        switch self {
        case let .sqlite(code, message):
            return "Clipboard history error (\(code)): \(message)"
        case let .invalidDatabase(message):
            return message
        }
    }
}
