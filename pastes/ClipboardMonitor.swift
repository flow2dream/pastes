//
//  ClipboardMonitor.swift
//  pastes
//
//  Created by hai on 2026/6/17.
//

import AppKit
import ApplicationServices

final class ClipboardMonitor {
    private var timer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var onCopy: ((String, Data?) -> Void)?
    var onCopyImage: ((Data) -> Void)?
    var isCopying = false

    func start(interval: TimeInterval = 0.5, onCopy: @escaping (String, Data?) -> Void) {
        self.onCopy = onCopy
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkPasteboard()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
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
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard !isCopying else { isCopying = false; return }

        let types = pasteboard.types ?? []

        // Check for filenames FIRST (Finder file copy)
        // This must come before .tiff check because Finder puts both
        // file path AND a TIFF preview on the pasteboard for image files
        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if types.contains(filenamesType),
           let plist = pasteboard.propertyList(forType: filenamesType) as? [String],
           let path = plist.first {
            if isImageFile(path), let data = loadImageData(from: path) {
                print("[Pastes] -> Image file from Finder: \(path)")
                onCopyImage?(data)
            }
            // Skip non-image files entirely
            return
        }

        // Check for raw image data (e.g. screenshot, copied image pixels)
        if types.contains(.tiff) || types.contains(.png) {
            if let data = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png) {
                print("[Pastes] -> Raw image data: \(data.count) bytes")
                onCopyImage?(data)
            }
            return
        }

        // Check for file URLs
        if types.contains(.fileURL) {
            if let urlString = pasteboard.string(forType: .fileURL),
               let url = URL(string: urlString) {
                let path = url.path
                if isImageFile(path), let data = loadImageData(from: path) {
                    print("[Pastes] -> Image from file URL: \(path)")
                    onCopyImage?(data)
                }
            }
            return
        }

        // Check if string is actually a file path to an image
        if let text = pasteboard.string(forType: .string) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("/") && isImageFile(trimmed) {
                if let data = loadImageData(from: trimmed) {
                    print("[Pastes] -> Image from string path: \(trimmed)")
                    onCopyImage?(data)
                    return
                }
            }
            if !trimmed.isEmpty {
                let rtfData = pasteboard.data(forType: .rtf)
                onCopy?(text, rtfData)
            }
        }
    }

    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Request accessibility permission if not already granted.
    /// Returns true if permission is already granted.
    @discardableResult
    static func requestAccessibility() -> Bool {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            // Show system prompt to grant accessibility permission
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
        return trusted
    }

    /// Simulate Cmd+V to paste into the frontmost app.
    static func simulatePaste() {
        guard AXIsProcessTrusted() else {
            requestAccessibility()
            return
        }

        let source = CGEventSource(stateID: .combinedSessionState)

        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) {
            keyDown.flags = .maskCommand
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
        }

        usleep(50_000)

        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) {
            keyUp.flags = .maskCommand
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}
