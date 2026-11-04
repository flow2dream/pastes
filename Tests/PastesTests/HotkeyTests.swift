import AppKit
import Carbon.HIToolbox
import Testing
@testable import pastes

@Suite("Hotkey formatting and modifier conversion")
struct HotkeyTests {
    @Test @MainActor
    func modifierCombinationsRoundTrip() {
        let supported = [cmdKey, optionKey, controlKey, shiftKey]
        for combination in 0..<16 {
            var carbon = 0
            for (index, modifier) in supported.enumerated() where combination & (1 << index) != 0 {
                carbon |= modifier
            }
            let flags = HotkeyManager.intToModifierFlags(carbon)
            #expect(HotkeyManager.modifierFlagsToInt(flags) == carbon)
        }
    }

    @Test @MainActor
    func unrelatedEventFlagsAreExcluded() {
        let flags: NSEvent.ModifierFlags = [.command, .shift, .capsLock, .numericPad, .function]
        #expect(HotkeyManager.modifierFlagsToInt(flags) == (cmdKey | shiftKey))
        #expect(HotkeyManager.intToModifierFlags(cmdKey | shiftKey) == [.command, .shift])
    }

    @Test @MainActor
    func displayUsesConsistentModifierOrderAndNamedKeys() {
        #expect(HotkeyManager.formatDisplay(keyCode: kVK_ANSI_V,
                                          modifiers: cmdKey | optionKey | controlKey | shiftKey) == "⌘⌥⌃⇧V")
        #expect(HotkeyManager.formatDisplay(keyCode: kVK_Space, modifiers: controlKey) == "⌃Space")
        #expect(HotkeyManager.keyCodeToString(kVK_Return) == "↩")
        #expect(HotkeyManager.keyCodeToString(kVK_LeftArrow) == "←")
        #expect(HotkeyManager.keyCodeToString(-1) == nil)
        #expect(HotkeyManager.formatDisplay(keyCode: kVK_F8, modifiers: 0) == "F8")
    }

    @Test @MainActor
    func invalidCandidateDoesNotChangeSavedBinding() {
        // Rejected before any Carbon call, so this test never reserves a global key.
        let manager = HotkeyManager.shared
        let previousKeyCode = manager.keyCode
        let previousModifiers = manager.modifiers
        #expect(!manager.update(keyCode: -1, modifiers: cmdKey))
        #expect(manager.keyCode == previousKeyCode)
        #expect(manager.modifiers == previousModifiers)
        #expect(manager.registrationError != nil)
    }
    @Test @MainActor
    func screenshotAndShelfAcceptSingleModifiersAndFunctionKeys() {
        #expect(HotkeyManager.accepts(keyCode: kVK_F1, modifiers: 0))
        #expect(HotkeyManager.accepts(keyCode: kVK_F8, modifiers: 0))
        #expect(HotkeyManager.accepts(keyCode: kVK_ANSI_S, modifiers: controlKey))
        #expect(!HotkeyManager.accepts(keyCode: kVK_ANSI_S, modifiers: 0))
    }

    @Test @MainActor
    func duplicateAssignmentsReportConflictWithoutChangingPreferences() {
        let prefix = "PastesShortcutTest-\(UUID())"
        let first = HotkeyManager(prefix: prefix + "A", keyCode: kVK_F19, modifiers: controlKey | optionKey)
        let second = HotkeyManager(prefix: prefix + "B", keyCode: kVK_F18, modifiers: controlKey | optionKey)
        #expect(!second.update(keyCode: first.keyCode, modifiers: first.modifiers))
        #expect(second.keyCode == kVK_F18)
        #expect(second.registrationError != nil)
    }

    @Test @MainActor
    func recorderCapturesFunctionKeyAndRestoresFocusOnCancel() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let capture = KeyCaptureView(frame: .zero)
        window.contentView = capture
        var key: UInt16?
        var cancelled = false
        capture.onKeyDown = { key = $0.keyCode }
        capture.onCancel = { cancelled = true; capture.isRecording = false }
        capture.isRecording = true
        #expect(window.firstResponder === capture)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(kVK_F8)))
        capture.keyDown(with: event)
        #expect(key == UInt16(kVK_F8))
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(kVK_Escape)))
        capture.keyDown(with: escape)
        #expect(cancelled)
        #expect(!capture.isRecording)
    }

    @Test @MainActor
    func shortcutChangePersistsAndRefreshesAfterRecording() throws {
        let prefix = "Pastes-ShortcutRegistration-\(UUID())"
        defer {
            UserDefaults.standard.removeObject(forKey: prefix + "_keyCode")
            UserDefaults.standard.removeObject(forKey: prefix + "_modifiers")
        }
        let manager = HotkeyManager(prefix: prefix, keyCode: kVK_F19, modifiers: controlKey | optionKey | shiftKey | cmdKey, signature: 0x54535448)
        defer { manager.unregister() }
        HotkeyManager.beginRecording()
        let changed = manager.update(keyCode: kVK_F20, modifiers: controlKey | optionKey | shiftKey | cmdKey)
        HotkeyManager.endRecording()
        #expect(changed, Comment(rawValue: manager.registrationError ?? ""))
        #expect(manager.keyCode == kVK_F20)
        #expect(manager.displayString.hasSuffix("F20"))
        let reopened = HotkeyManager(prefix: prefix, keyCode: kVK_F19, modifiers: controlKey, signature: 0x54535449)
        #expect(reopened.keyCode == kVK_F20)
        #expect(reopened.modifiers == manager.modifiers)
    }

}
