import AppKit

/// Only a disposable copy is offered to external drag destinations.
/// Apps request copy; Finder can move it; the managed library file remains available for undo.
@MainActor
final class CaptureDragFile {
    let directory: URL
    let file: URL
    let item: CaptureItem
    init(source: URL, item: CaptureItem) throws {
        self.item = item
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Pastes-Drag-\(UUID())", isDirectory: true)
        let baseName = URL(fileURLWithPath: item.title).deletingPathExtension().lastPathComponent
        file = directory.appendingPathComponent((baseName.isEmpty ? "Capture" : baseName) + "." + source.pathExtension)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do { try FileManager.default.copyItem(at: source, to: file) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    func finish(operation: NSDragOperation, onFiled: @escaping (CaptureItem) -> Void, onError: @escaping (Error) -> Void) {
        if operation.contains(.delete) {
            do {
                // The Dock requests deletion; the source performs it on the disposable copy.
                try FileManager.default.trashItem(at: file, resultingItemURL: nil)
                onFiled(item)
            } catch { onError(error) }
        } else if operation.contains(.move) {
            // Finder may finish moving after the session callback. Never remove the shelf entry on a failed move.
            Task {
                for _ in 0..<10 {
                    if !FileManager.default.fileExists(atPath: file.path) { onFiled(item); return }
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
        }
        // File-URL consumers may read asynchronously after a successful copy.
        let temporary = directory
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 600) {
            try? FileManager.default.removeItem(at: temporary)
        }
    }
}
