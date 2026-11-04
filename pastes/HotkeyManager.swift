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
    private static let managers = NSHashTable<HotkeyManager>.weakObjects()
    static let shared = HotkeyManager()
    private static var recordingCount = 0
    static func beginRecording() {
        recordingCount += 1
        guard recordingCount == 1 else { return }
        for manager in managers.allObjects {
            if let ref = manager.hotKeyRef { UnregisterEventHotKey(ref); manager.hotKeyRef = nil }
            manager.activeHotKeyID = nil
        }
    }
    static func endRecording() {
        recordingCount = max(0, recordingCount - 1)
        guard recordingCount == 0 else { return }
        for manager in managers.allObjects where manager.onTrigger != nil {
            _ = manager.replaceRegistration(with: Binding(keyCode: manager.keyCode, modifiers: manager.modifiers))
        }
    }
    static func accepts(keyCode: Int, modifiers: Int) -> Bool {
        modifiers != 0 || [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20].contains(keyCode)
    }

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
    private let keyCodeKey: String
    private let modifiersKey: String
    private let initialKeyCode: Int
    private let initialModifiers: Int
    private let signature: UInt32

    static var defaultModifiers: Int {
        cmdKey | shiftKey | (AppEnvironment.isDevelopment ? optionKey : 0)
    }

    static var defaultDisplayString: String {
        formatDisplay(keyCode: kVK_ANSI_V, modifiers: defaultModifiers)
    }

    var keyCode: Int {
        get { defaults.object(forKey: keyCodeKey) as? Int ?? initialKeyCode }
    }

    var modifiers: Int {
        get { defaults.object(forKey: modifiersKey) as? Int ?? initialModifiers }
    }

    init(prefix: String = "hotkey", keyCode: Int = kVK_ANSI_V,
         modifiers: Int? = nil, signature: UInt32 = 0x505354) {
        keyCodeKey = prefix + "_keyCode"
        modifiersKey = prefix + "_modifiers"
        initialKeyCode = keyCode
        initialModifiers = modifiers ?? Self.defaultModifiers
        self.signature = signature
        Self.managers.add(self)
    }

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
                guard status == noErr else { return OSStatus(eventNotHandledErr) }
                let identifier = pressedID.id
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                guard pressedID.signature == manager.signature else { return OSStatus(eventNotHandledErr) }
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
            EventHotKeyID(signature: signature, id: identifier),
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
        guard Self.accepts(keyCode: keyCode, modifiers: modifiers) else {
            registrationError = C("请使用功能键，或带 ⌘ / ⌥ / ⌃ / ⇧ 的组合键。", "Use a function key or a key with modifiers.")
            return false
        }
        let commonCommandKeys = [kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_Z, kVK_ANSI_A, kVK_ANSI_S, kVK_ANSI_P, kVK_ANSI_F, kVK_ANSI_H, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_Space, kVK_Tab]
        if (modifiers == cmdKey && commonCommandKeys.contains(keyCode)) || (modifiers == cmdKey | shiftKey && [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_Z].contains(keyCode)) {
            registrationError = C("这是系统或常用编辑快捷键，请换一个组合。", "This is a system or common editing shortcut. Choose another combination.")
            return false
        }
        guard !Self.managers.allObjects.contains(where: { $0 !== self && $0.keyCodeKey != keyCodeKey && $0.keyCode == keyCode && $0.modifiers == modifiers }) else {
            registrationError = C("这个快捷键已用于本应用的其他功能。", "This shortcut is assigned to another action in this app.")
            return false
        }
        guard replaceRegistration(with: Binding(keyCode: keyCode, modifiers: modifiers)) else { return false }
        // Persist only after success; a conflict leaves the old defaults untouched.
        defaults.set(keyCode, forKey: keyCodeKey)
        defaults.set(modifiers, forKey: modifiersKey)
        objectWillChange.send()
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
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        if let index = functionKeys.firstIndex(of: code) { return "F\(index + 1)" }
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
