import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Prepares clipboard data before claiming ownership, then returns that exact generation.
@MainActor
struct ClipboardWriter {
    let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    @discardableResult
    func write(_ item: ClipboardItem) throws -> Int {
        let image: (type: NSPasteboard.PasteboardType, data: Data)?
        let types: [NSPasteboard.PasteboardType]
        if item.isImage {
            guard let data = item.imageData else { throw WriteError.invalidImage }
            let representation = try imageRepresentation(data)
            image = representation
            types = [representation.type]
        } else {
            image = nil
            types = item.rtfData == nil ? [.string] : [.string, .rtf]
        }

        let changeCount = pasteboard.declareTypes(types, owner: nil)
        if let image {
            guard pasteboard.setData(image.data, forType: image.type) else { throw WriteError.writeFailed }
        } else {
            if let rtfData = item.rtfData {
                guard pasteboard.setData(rtfData, forType: .rtf) else { throw WriteError.writeFailed }
            }
            guard pasteboard.setString(item.content, forType: .string) else { throw WriteError.writeFailed }
        }
        guard pasteboard.changeCount == changeCount else { throw WriteError.ownershipChanged }
        return changeCount
    }

    private func imageRepresentation(_ data: Data) throws -> (type: NSPasteboard.PasteboardType, data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil,
              let identifier = CGImageSourceGetType(source) else {
            throw WriteError.invalidImage
        }
        switch identifier as String {
        case UTType.png.identifier: return (.png, data)
        case UTType.tiff.identifier: return (.tiff, data)
        default:
            guard let image = NSImage(data: data), let tiff = image.tiffRepresentation else {
                throw WriteError.invalidImage
            }
            return (.tiff, tiff)
        }
    }

    private enum WriteError: LocalizedError {
        case invalidImage
        case writeFailed
        case ownershipChanged

        var errorDescription: String? {
            switch self {
            case .invalidImage: return "The saved image could not be decoded."
            case .writeFailed: return "The clipboard could not be written."
            case .ownershipChanged: return "The clipboard changed before copying finished. Please try again."
            }
        }
    }
}
