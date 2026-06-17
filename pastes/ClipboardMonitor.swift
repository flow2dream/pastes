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

    func checkPasteboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard !isCopying else { isCopying = false; return }

        let types = pasteboard.types ?? []

        // Check for image data first
        if types.contains(.tiff) || types.contains(.png) {
            if let data = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png) {
                onCopyImage?(data)
            }
            return
        }

        // Skip file URLs
        if types.contains(.fileURL) {
            return
        }

        if let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let rtfData = pasteboard.data(forType: .rtf)
            onCopy?(text, rtfData)
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
