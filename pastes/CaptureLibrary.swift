import AppKit
import Combine
import CryptoKit
import UniformTypeIdentifiers
import AVFoundation

struct CaptureItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case image, movie }
    var id: UUID
    var filename: String
    var title: String
    var kind: Kind
    var created: Date
    var digest: String
    var isPinned = false
    var isHidden = false
    var historyID: UUID?
}

/// File-backed media, independent of clipboard history retention and user-owned originals.
@MainActor
final class CaptureLibrary: ObservableObject {
    struct Arrival: Equatable {
        let itemID: UUID
        let token: UUID
    }
    @Published private(set) var latestArrival: Arrival?
    private(set) var arrivalTokens: [UUID: UUID] = [:]
    private(set) var arrivalOrigins: [UUID: CGRect] = [:]
    @Published private(set) var items: [CaptureItem] = []
    /// Taken-down images still own their files, but do not occupy a shelf slot.
    /// This state is intentionally transient so existing media survives app exit.
    @Published private(set) var heldItemIDs: Set<UUID> = []
    private var undoGroups: [[UUID]] = []
    private(set) var maximumItems = 0
    private var limitIncludesPins = false
    let directory: URL
    private var manifest: URL { directory.appendingPathComponent("library.json") }
    var visibleItems: [CaptureItem] {
        items.filter { !$0.isHidden && !heldItemIDs.contains($0.id) }.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.created > $1.created
        }
    }
    var canUndo: Bool { !undoGroups.isEmpty }

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: manifest.path) {
            let decoded = try JSONDecoder().decode([CaptureItem].self, from: Data(contentsOf: manifest))
            // Never let a damaged manifest reference files outside its own directory.
            guard decoded.allSatisfy({ $0.filename == URL(fileURLWithPath: $0.filename).lastPathComponent && !$0.filename.hasPrefix(".") }),
                  Set(decoded.map(\.id)).count == decoded.count else { throw CaptureError.invalidMedia }
            items = decoded
        }
    }

    /// Pins are exempt. Overflow is hidden, never deleted from disk.
    func setMaximumItems(_ value: Int, includingPins: Bool = false) throws {
        let limit = max(0, value)
        try commit(items, limit: limit, includingPins: includingPins)
        maximumItems = limit
        limitIncludesPins = includingPins
    }

    func url(for item: CaptureItem) -> URL { directory.appendingPathComponent(item.filename) }

    @discardableResult
    func takeFromShelf(_ id: UUID) -> Bool {
        guard !heldItemIDs.contains(id), items.contains(where: { $0.id == id && !$0.isHidden }) else { return false }
        arrivalTokens[id] = nil
        arrivalOrigins[id] = nil
        heldItemIDs.insert(id)
        return true
    }

    func returnToShelf(_ id: UUID, origin: CGRect) throws {
        guard heldItemIDs.contains(id) else { return }
        guard var item = items.first(where: { $0.id == id && !$0.isHidden }) else {
            releaseHeldItem(id)
            return
        }
        // Treat a returned image as a new arrival for retention. Keep it held
        // until the manifest write succeeds, allowing failed closes to retry.
        item.created = Date()
        try commit(items.map { $0.id == id ? item : $0 }, returningHeldID: id)
        releaseHeldItem(id)
        animateArrival(id, origin: origin)
    }

    /// Raw teardown restores the existing entry without importing or animating.
    func releaseHeldItem(_ id: UUID) {
        if heldItemIDs.contains(id) { heldItemIDs.remove(id) }
    }

    @discardableResult
    func importImage(_ data: Data, title: String, historyID: UUID? = nil, forceNew: Bool = false, origin: CGRect? = nil) throws -> CaptureItem {
        guard let image = NSImage(data: data), let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { throw CaptureError.invalidMedia }
        let digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        if !forceNew, let existing = items.first(where: { $0.digest == digest && $0.kind == .image && !heldItemIDs.contains($0.id) }) {
            var updated = existing
            updated.isHidden = false
            updated.created = Date()
            if let historyID { updated.historyID = historyID }
            try replace(updated)
            announceArrival(updated, origin: origin)
            return updated
        }
        let id = UUID()
        let item = CaptureItem(id: id, filename: "\(id).png", title: title, kind: .image,
                               created: Date(), digest: digest, historyID: historyID)
        try png.write(to: url(for: item), options: .atomic)
        do { try commit(items + [item]) } catch {
            try? FileManager.default.removeItem(at: url(for: item)); throw error
        }
        announceArrival(item, origin: origin)
        return item
    }

    /// Called with a stable file. Only copies it; never moves or edits the source.
    @discardableResult
    func importFile(_ source: URL, origin: CGRect? = nil) throws -> CaptureItem {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CaptureError.invalidMedia }
        let type = UTType(filenameExtension: source.pathExtension)
        if type?.conforms(to: .image) == true {
            return try importImage(Data(contentsOf: source), title: source.lastPathComponent, origin: origin)
        }
        throw CaptureError.invalidMedia
    }

    /// Copy/hash recordings off the main actor, then publish their manifest atomically.
    func importMedia(_ source: URL, origin: CGRect? = nil) async throws -> CaptureItem {
        guard UTType(filenameExtension: source.pathExtension)?.conforms(to: .movie) == true else {
            return try importFile(source, origin: origin)
        }
        let asset = AVURLAsset(url: source)
        guard (try? await asset.load(.isPlayable)) == true else { throw CaptureError.invalidMedia }
        let id = UUID()
        let filename = "\(id).\(source.pathExtension.lowercased())"
        let destination = directory.appendingPathComponent(filename)
        let digest: String
        do {
            digest = try await Task.detached(priority: .utility) {
                let before = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard before.isRegularFile == true, before.isSymbolicLink != true else { throw CaptureError.invalidMedia }
                try FileManager.default.copyItem(at: source, to: destination)
                let digest = try Self.fileDigest(destination)
                let after = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else { throw CaptureError.invalidMedia }
                return digest
            }.value
            try Task.checkCancellation()
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
        if let existing = items.first(where: { $0.digest == digest && $0.kind == .movie && !heldItemIDs.contains($0.id) }) {
            try? FileManager.default.removeItem(at: destination)
            var updated = existing; updated.isHidden = false; updated.created = Date()
            try replace(updated); announceArrival(updated, origin: origin); return updated
        }
        let item = CaptureItem(id: id, filename: filename, title: source.lastPathComponent,
                               kind: .movie, created: Date(), digest: digest)
        do { try commit(items + [item]) } catch {
            try? FileManager.default.removeItem(at: destination); throw error
        }
        announceArrival(item, origin: origin)
        return item
    }

    func animateArrival(_ id: UUID, origin: CGRect? = nil) {
        guard let item = items.first(where: { $0.id == id && !$0.isHidden }) else { return }
        announceArrival(item, origin: origin)
    }
    private func announceArrival(_ item: CaptureItem, origin: CGRect?) {
        let visible = Set(visibleItems.map(\.id))
        arrivalTokens = arrivalTokens.filter { visible.contains($0.key) }
        arrivalOrigins = arrivalOrigins.filter { visible.contains($0.key) }
        guard visible.contains(item.id) else { return }
        let arrival = Arrival(itemID: item.id, token: UUID())
        arrivalTokens[item.id] = arrival.token
        arrivalOrigins[item.id] = origin.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
        latestArrival = arrival
    }

    nonisolated static func fileDigest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Write a new immutable file, then atomically swap the manifest pointer. A failed
    /// write/manifest update leaves the previous image intact. Keep old versions for open editors.
    @discardableResult
    func overwriteImage(id: UUID, expectedDigest: String, data: Data, historyID: UUID? = nil) throws -> CaptureItem {
        guard var item = items.first(where: { $0.id == id }), item.kind == .image else { throw CaptureError.invalidMedia }
        guard item.digest == expectedDigest else { throw CaptureError.editConflict }
        guard let image = NSImage(data: data), let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { throw CaptureError.invalidMedia }
        item.filename = "\(UUID()).png"
        item.digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        if let historyID { item.historyID = historyID }
        let target = url(for: item)
        try png.write(to: target, options: .atomic)
        do { try replace(item) }
        catch { try? FileManager.default.removeItem(at: target); throw error }
        return item
    }

    func link(_ id: UUID, historyID: UUID) throws {
        guard var item = items.first(where: { $0.id == id }) else { return }
        item.historyID = historyID; try replace(item)
    }
    func togglePin(_ id: UUID) throws {
        guard var item = items.first(where: { $0.id == id }) else { return }
        item.isPinned.toggle(); try replace(item)
    }
    /// The same left-to-right order is used by layout and directional removal.
    var shelfItems: [CaptureItem] {
        visibleItems.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if $0.created != $1.created { return $0.created < $1.created }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    enum RemovalSide { case left, right }
    func removalIDs(relativeTo id: UUID, side: RemovalSide) -> [UUID] {
        let ordered = shelfItems
        guard let index = ordered.firstIndex(where: { $0.id == id }) else { return [] }
        return (side == .left ? Array(ordered.prefix(index)) : Array(ordered.dropFirst(index + 1))).map(\.id)
    }
    func remove(_ id: UUID) throws { try remove(ids: [id]) }
    func remove(ids: [UUID]) throws {
        let requested = Set(ids)
        let removed = items.filter { requested.contains($0.id) && !$0.isHidden }.map(\.id)
        guard !removed.isEmpty else { return }
        let targets = Set(removed)
        try commit(items.map { original in
            var item = original
            if targets.contains(item.id) { item.isHidden = true }
            return item
        })
        undoGroups.append(removed)
    }
    func undo() throws {
        guard let group = undoGroups.last else { return }
        let targets = Set(group)
        let hidden = items.filter { targets.contains($0.id) && $0.isHidden }.sorted { $0.created < $1.created }
        let now = Date()
        let dates = Dictionary(uniqueKeysWithValues: hidden.enumerated().map { ($0.element.id, now.addingTimeInterval(Double($0.offset) * 0.000001)) })
        try commit(items.map { original in
            var item = original
            if let date = dates[item.id] { item.isHidden = false; item.created = date }
            return item
        })
        undoGroups.removeLast()
    }
    /// Explicit cleanup only: hidden media can consume disk until the user chooses this action.
    func purgeHidden() throws {
        let hidden = items.filter { $0.isHidden && !heldItemIDs.contains($0.id) }
        try commit(items.filter { !$0.isHidden || heldItemIDs.contains($0.id) })
        undoGroups.removeAll()
        for item in hidden { try FileManager.default.removeItem(at: url(for: item)) }
    }
    private func replace(_ item: CaptureItem) throws {
        try commit(items.map { $0.id == item.id ? item : $0 })
    }
    private func commit(_ proposed: [CaptureItem], limit: Int? = nil, includingPins: Bool? = nil,
                        returningHeldID: UUID? = nil) throws {
        var updated = proposed
        let maximum = limit ?? maximumItems
        if maximum > 0 {
            let candidates = updated.filter {
                !$0.isHidden && !$0.isPinned && (!heldItemIDs.contains($0.id) || $0.id == returningHeldID)
            }.sorted {
                if $0.created != $1.created { return $0.created > $1.created }
                return $0.id.uuidString < $1.id.uuidString
            }
            let pinnedCount = updated.filter {
                !$0.isHidden && $0.isPinned && (!heldItemIDs.contains($0.id) || $0.id == returningHeldID)
            }.count
            let capacity = (includingPins ?? limitIncludesPins) ? max(0, maximum - pinnedCount) : maximum
            let overflow = Set(candidates.dropFirst(capacity).map(\.id))
            for index in updated.indices where overflow.contains(updated[index].id) {
                updated[index].isHidden = true
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(updated).write(to: manifest, options: .atomic)
        items = updated
    }
}

enum CaptureError: LocalizedError {
    case invalidMedia, unavailable, invalidTrim, editConflict
    var errorDescription: String? {
        switch self {
        case .editConflict: return C("这张图片已在其他编辑窗口中更新，请另存副本或重新打开编辑。", "This image was updated in another editor. Save a copy or reopen it before overwriting.")
        case .invalidMedia: return C("无法读取图片或录屏文件。", "Cannot read this image or recording.")
        case .unavailable: return C("系统编辑器暂不可用，请使用“打开文件”编辑。", "The system editor is unavailable. Use Open File to edit.")
        case .invalidTrim: return C("无法裁剪此录屏。原始文件已保留。", "Cannot trim this recording. The original is preserved.")
        }
    }
}

func C(_ chinese: String, _ english: String) -> String {
    LocalizationManager.shared.language == .zh ? chinese : english
}
