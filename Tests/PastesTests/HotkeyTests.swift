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
}
