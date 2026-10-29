//
//  ClipboardMonitor.swift
//  pastes
//
//  Created by hai on 2026/6/17.
//

import AppKit
import ApplicationServices

@MainActor
final class ClipboardMonitor {
    let pasteboard: NSPasteboard
    private var timer: Timer?
    private var lastChangeCount: Int
    private var ownChangeCount: Int?
    private var onCopy: ((String, Data?) -> Void)?
    var onCopyImage: ((Data) -> Void)?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        lastChangeCount = pasteboard.changeCount
    }

    func start(interval: TimeInterval = 0.5, onCopy: @escaping (String, Data?) -> Void) {
        stop()
        self.onCopy = onCopy
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPasteboard() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Acknowledge the exact ownership generation returned by ClipboardWriter.
    /// A subsequent external write has a different generation and must still be read.
    func acknowledgeOwnWrite(changeCount: Int) {
        ownChangeCount = changeCount
    }

    deinit {
        timer?.invalidate()
    }

    /// Image file extensions to recognize
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif", "icns", "ico", "svg"
    ]

    /// Check if a file path points to an image
    private func isImageFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return Self.imageExtensions.contains(ext)
    }

    /// Load image data from a file path
    private func loadImageData(from path: String) -> Data? {
        let url = URL(fileURLWithPath: path)
        guard let image = NSImage(contentsOf: url) else { return nil }
        // Convert to PNG for consistent storage
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return image.tiffRepresentation
        }
        return png
    }

    func checkPasteboard() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        if ownChangeCount == changeCount {
            lastChangeCount = changeCount
            ownChangeCount = nil
            return
        }
        if let ownChangeCount, changeCount > ownChangeCount {
            self.ownChangeCount = nil
        }
        let types = pasteboard.types ?? []
        guard let content = readContent(types: types), pasteboard.changeCount == changeCount else { return }

        // clearContents/declareTypes change the generation; setData/setString do not.
        // An empty or promised payload remains eligible for the next poll.
        lastChangeCount = changeCount
        switch content {
        case let .text(text, rtfData): onCopy?(text, rtfData)
        case let .image(data): onCopyImage?(data)
        case .ignored: break
        }
    }

    private enum Content {
        case text(String, Data?)
        case image(Data)
        case ignored
    }

    private func readContent(types: [NSPasteboard.PasteboardType]) -> Content? {
        // Check for filenames FIRST (Finder file copy)
        // This must come before .tiff check because Finder puts both
        // file path AND a TIFF preview on the pasteboard for image files
        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if types.contains(filenamesType) {
            guard let paths = pasteboard.propertyList(forType: filenamesType) as? [String],
                  let path = paths.first else { return nil }
            guard isImageFile(path) else { return .ignored }
            return loadImageData(from: path).map(Content.image)
        }

        // File URLs take priority over thumbnails that non-image files may advertise.
        if types.contains(.fileURL) {
            guard let urlString = pasteboard.string(forType: .fileURL),
                  let url = URL(string: urlString) else { return nil }
            guard url.isFileURL, isImageFile(url.path) else { return .ignored }
            if let data = loadImageData(from: url.path) {
                return .image(data)
            }
            // An advertised raw image can still be used if its source file is unavailable.
        }

        // Check for raw image data (e.g. screenshot, copied image pixels).
        if types.contains(.tiff) || types.contains(.png) {
            if types.contains(.tiff), let data = pasteboard.data(forType: .tiff) {
                return .image(data)
            }
            if types.contains(.png), let data = pasteboard.data(forType: .png) {
                return .image(data)
            }
            return nil
        }

        // Check if string is actually a file path to an image
        let rtfData = pasteboard.data(forType: .rtf)
        if types.contains(.rtf), rtfData == nil { return nil }
        let text: String?
        if let plainText = pasteboard.string(forType: .string) {
            text = plainText
        } else if !types.contains(.string), let rtfData {
            text = NSAttributedString(rtf: rtfData, documentAttributes: nil)?.string
        } else {
            text = nil
        }
        if let text {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("/") && isImageFile(trimmed) {
                if let data = loadImageData(from: trimmed) {
                    return .image(data)
                }
            }
            if !trimmed.isEmpty {
                return .text(text, rtfData)
            }
        }
        return nil
    }

    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Request permission to synthesize keyboard events if not already granted.
    /// Returns the event-posting permission result after an optional request.
    @discardableResult
    static func requestAccessibility() -> Bool {
        PastePermission.requestIfNeeded()
    }

    /// Simulate Cmd+V to paste into the frontmost app.
    @discardableResult
    static func simulatePaste() -> Bool {
        PasteTrace.record("paste_permission_check", details: ["axTrusted": AXIsProcessTrusted(), "canPostEvents": CGPreflightPostEventAccess()])
        guard PastePermission.isGranted else {
            PasteTrace.record("paste_blocked", details: ["reason": "event_posting_not_allowed"])
            PasteFeedback.shared.needsPermission = true
            return false
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            PasteTrace.record("paste_blocked", details: ["reason": "event_creation_failed"])
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        usleep(50_000)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
        PasteTrace.record("paste_events_posted", details: ["tap": "annotatedSession"])
        return true
    }
}
