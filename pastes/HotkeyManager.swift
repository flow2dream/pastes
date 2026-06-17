//
//  HotkeyManager.swift
//  pastes
//
//  Created by hai on 2026/6/17.
//

import Carbon.HIToolbox
import AppKit

final class HotkeyManager {
    static let shared = HotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var onTrigger: (() -> Void)?

    private let defaults = UserDefaults.standard
    private let keyCodeKey = "hotkey_keyCode"
    private let modifiersKey = "hotkey_modifiers"

    var keyCode: Int {
        get { defaults.object(forKey: keyCodeKey) as? Int ?? kVK_ANSI_V }
        set { defaults.set(newValue, forKey: keyCodeKey) }
    }

    var modifiers: Int {
        get { defaults.object(forKey: modifiersKey) as? Int ?? (cmdKey | shiftKey) }
        set { defaults.set(newValue, forKey: modifiersKey) }
    }

    private init() {}

    func register(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
        unregister()

        // Install event handler
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, refcon -> OSStatus in
                guard let refcon else { return noErr }
                DispatchQueue.main.async {
                    Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue().onTrigger?()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        guard status == noErr else {
            print("Failed to install event handler: \(status)")
            return
        }

        // Register hotkey
        let hotKeyID = EventHotKeyID(
            signature: OSType(0x505354),  // "PST"
            id: 1
        )

        let regStatus = RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if regStatus != noErr {
            print("Failed to register hotkey: \(regStatus)")
        }
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }

    func update(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        if let onTrigger {
            register(onTrigger: onTrigger)
        }
    }

    // MARK: - Display

    var displayString: String {
        Self.formatDisplay(keyCode: keyCode, modifiers: modifiers)
    }

    static func formatDisplay(keyCode: Int, modifiers: Int) -> String {
        var parts: [String] = []
        if modifiers & cmdKey != 0 { parts.append("\u{2318}") }
        if modifiers & optionKey != 0 { parts.append("\u{2325}") }
        if modifiers & controlKey != 0 { parts.append("\u{2303}") }
        if modifiers & shiftKey != 0 { parts.append("\u{21E7}") }
        if let char = keyCodeToString(keyCode) {
            parts.append(char)
        }
        return parts.joined()
    }

    // MARK: - Modifier Conversion

    static func modifierFlagsToInt(_ flags: NSEvent.ModifierFlags) -> Int {
        var value = 0
        if flags.contains(.command) { value |= cmdKey }
        if flags.contains(.option) { value |= optionKey }
        if flags.contains(.control) { value |= controlKey }
        if flags.contains(.shift) { value |= shiftKey }
        return value
    }

    static func intToModifierFlags(_ value: Int) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if value & cmdKey != 0 { flags.insert(.command) }
        if value & optionKey != 0 { flags.insert(.option) }
        if value & controlKey != 0 { flags.insert(.control) }
        if value & shiftKey != 0 { flags.insert(.shift) }
        return flags
    }

    // MARK: - Key Code Mapping

    static func keyCodeToString(_ code: Int) -> String? {
        switch code {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"
        case kVK_Return: return "\u{21A9}"
        case kVK_Tab: return "\u{21E5}"
        case kVK_Escape: return "\u{238B}"
        case kVK_Delete: return "\u{232B}"
        case kVK_UpArrow: return "\u{2191}"
        case kVK_DownArrow: return "\u{2193}"
        case kVK_LeftArrow: return "\u{2190}"
        case kVK_RightArrow: return "\u{2192}"
        default: return nil
        }
    }
}
