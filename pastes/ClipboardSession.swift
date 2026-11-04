import AppKit
import Combine

/// One monitor for the application lifetime, shared by history and the capture shelf.
@MainActor
final class ClipboardSession: ObservableObject {
    let store: ClipboardStore
    let monitor: ClipboardMonitor
    var onImage: ((Data, UUID) -> Void)?
    private let imageSource = CaptureImageSource()
    private(set) var copiedImageBounds: CGRect?
    @Published var errorMessage: String?
    private let defaults: UserDefaults
    var limit: Int { defaults.object(forKey: "maxClipboardItems") as? Int ?? 20 }
    init(store: ClipboardStore, pasteboard: NSPasteboard? = nil, defaults: UserDefaults = .standard) {
        self.store = store; self.defaults = defaults
        monitor = ClipboardMonitor(pasteboard: pasteboard ?? AppEnvironment.pasteboard)
    }
    func start() {
        if monitor.pasteboard.name == NSPasteboard.general.name { imageSource.start() }
        monitor.onCopyImage = { [weak self] data in
            guard let self else { return }
            copiedImageBounds = NSImage(data: data).flatMap { self.imageSource.consume(imageSize: $0.size) }
            do {
                // Normalize copied pixels to the same format used by screenshot imports.
                let normalized: Data
                if let image = NSImage(data: data), let tiff = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
                    normalized = png
                } else { normalized = data }
                let id = try store.addImage(normalized, limit: limit)
                onImage?(normalized, id)
            } catch { errorMessage = error.localizedDescription }
        }
        monitor.start { [weak self] text, rtf in
            guard let self else { return }
            do { try store.addText(text, rtfData: rtf, limit: limit) }
            catch { errorMessage = error.localizedDescription }
        }
    }
    func stop() { monitor.stop(); imageSource.stop(); copiedImageBounds = nil }
    @discardableResult
    func copy(_ item: ClipboardItem) throws -> Int {
        let generation = try ClipboardWriter(pasteboard: monitor.pasteboard).write(item)
        monitor.acknowledgeOwnWrite(changeCount: generation)
        return generation
    }
    func copyFile(_ url: URL) throws {
        let board = monitor.pasteboard
        board.clearContents()
        guard board.writeObjects([url as NSURL]) else { throw CaptureError.invalidMedia }
        monitor.acknowledgeOwnWrite(changeCount: board.changeCount)
    }
}
