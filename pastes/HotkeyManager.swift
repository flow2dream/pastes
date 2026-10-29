//
//  HotkeyManager.swift
//  pastes
//
//  Created by hai on 2026/6/17.
//

import Carbon.HIToolbox
import AppKit
import Combine

@MainActor
final class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var onTrigger: (() -> Void)?
    private var activeBinding: Binding?
    private var activeHotKeyID: UInt32?
    private var nextHotKeyID: UInt32 = 1
    @Published private(set) var registrationError: String?

    private struct Binding: Equatable {
        let keyCode: Int
        let modifiers: Int
    }

    private let defaults = UserDefaults.standard
    private let keyCodeKey = "hotkey_keyCode"
    private let modifiersKey = "hotkey_modifiers"

    static var defaultModifiers: Int {
        cmdKey | shiftKey | (AppEnvironment.isDevelopment ? optionKey : 0)
    }

    static var defaultDisplayString: String {
        formatDisplay(keyCode: kVK_ANSI_V, modifiers: defaultModifiers)
    }

    var keyCode: Int {
        get { defaults.object(forKey: keyCodeKey) as? Int ?? kVK_ANSI_V }
    }

    var modifiers: Int {
        get { defaults.object(forKey: modifiersKey) as? Int ?? Self.defaultModifiers }
    }

    private init() {}

    @discardableResult
    func register(onTrigger: @escaping () -> Void) -> Bool {
        self.onTrigger = onTrigger
        return replaceRegistration(with: Binding(keyCode: keyCode, modifiers: modifiers))
    }

    private func installEventHandlerIfNeeded() -> Bool {
        if eventHandlerRef != nil { return true }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var handler: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, refcon -> OSStatus in
                guard let event, let refcon else { return OSStatus(eventNotHandledErr) }
                var pressedID = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &pressedID
                )
                guard status == noErr, pressedID.signature == OSType(0x505354) else { return OSStatus(eventNotHandledErr) }
                let identifier = pressedID.id
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                DispatchQueue.main.async { [weak manager] in
                    // Ignore queued events from a replaced or failed candidate binding.
                    guard let manager, manager.activeHotKeyID == identifier else { return }
                    manager.onTrigger?()
                }
                return noErr
            },
            1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler
        )
        guard status == noErr, let handler else {
            registrationError = "\(L("hotkey_handler_failed")) (\(status))"
            return false
        }
        eventHandlerRef = handler
        return true
    }

    private func replaceRegistration(with candidate: Binding) -> Bool {
        if hotKeyRef != nil, activeBinding == candidate {
            registrationError = nil
            return true
        }
        guard UInt32(exactly: candidate.keyCode) != nil,
              UInt32(exactly: candidate.modifiers) != nil else {
            registrationError = "\(L("hotkey_registration_failed")) (\(paramErr))"
            return false
        }
        guard installEventHandlerIfNeeded() else { return false }

        let identifier = nextHotKeyID
        nextHotKeyID = nextHotKeyID == UInt32.max ? 1 : nextHotKeyID + 1
        var candidateRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(candidate.keyCode), UInt32(candidate.modifiers),
            EventHotKeyID(signature: OSType(0x505354), id: identifier),
            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &candidateRef
        )
        guard status == noErr, let candidateRef else {
            if let candidateRef { UnregisterEventHotKey(candidateRef) }
            registrationError = "\(L("hotkey_registration_failed")) (\(status))"
            return false
        }

        // The old key remains usable until the candidate is confirmed registered.
        if let previousRef = hotKeyRef {
            let removalStatus = UnregisterEventHotKey(previousRef)
            guard removalStatus == noErr else {
                UnregisterEventHotKey(candidateRef)
                registrationError = "\(L("hotkey_registration_failed")) (\(removalStatus))"
                return false
            }
        }
        hotKeyRef = candidateRef
        activeHotKeyID = identifier
        activeBinding = candidate
        registrationError = nil
        return true
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        activeHotKeyID = nil
        activeBinding = nil
        onTrigger = nil
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }

    @discardableResult
    func update(keyCode: Int, modifiers: Int) -> Bool {
        guard replaceRegistration(with: Binding(keyCode: keyCode, modifiers: modifiers)) else { return false }
        // Persist only after success; a conflict leaves the old defaults untouched.
        defaults.set(keyCode, forKey: keyCodeKey)
        defaults.set(modifiers, forKey: modifiersKey)
        return true
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
