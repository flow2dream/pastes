//
//  SettingsView.swift
//  pastes
//
//  Created by hai on 2026/6/17.
//

import SwiftUI
import Carbon.HIToolbox
import ServiceManagement

struct SettingsView: View {
    @State private var isRecording = false
    @State private var recordedKeyCode: Int?
    @State private var recordedModifiers: Int?
    @State private var hotkeyManager = HotkeyManager.shared
    @AppStorage("maxClipboardItems") private var maxItems = 20
    @AppStorage("appLanguage") private var language: AppLanguage = .zh
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var showConflictAlert = false

    // System shortcuts that conflict
    private static let systemShortcuts: [(Int, Int)] = [
        (kVK_ANSI_Q, cmdKey),           // ⌘Q Quit
        (kVK_ANSI_W, cmdKey),           // ⌘W Close
        (kVK_ANSI_C, cmdKey),           // ⌘C Copy
        (kVK_ANSI_V, cmdKey),           // ⌘V Paste
        (kVK_ANSI_X, cmdKey),           // ⌘X Cut
        (kVK_ANSI_Z, cmdKey),           // ⌘Z Undo
        (kVK_ANSI_A, cmdKey),           // ⌘A Select All
        (kVK_ANSI_S, cmdKey),           // ⌘S Save
        (kVK_ANSI_P, cmdKey),           // ⌘P Print
        (kVK_ANSI_F, cmdKey),           // ⌘F Find
        (kVK_ANSI_H, cmdKey),           // ⌘H Hide
        (kVK_ANSI_M, cmdKey),           // ⌘M Minimize
        (kVK_ANSI_N, cmdKey),           // ⌘N New
        (kVK_ANSI_O, cmdKey),           // ⌘O Open
        (kVK_ANSI_P, cmdKey | shiftKey), // ⌘⇧P
        (kVK_ANSI_Z, cmdKey | shiftKey), // ⌘⇧Z Redo
        (kVK_ANSI_3, cmdKey | shiftKey), // ⌘⇧3 Screenshot
        (kVK_ANSI_4, cmdKey | shiftKey), // ⌘⇧4 Screenshot
        (kVK_ANSI_5, cmdKey | shiftKey), // ⌘⇧5 Screenshot
        (kVK_Space, cmdKey),            // ⌘Space Spotlight
        (kVK_Space, cmdKey | optionKey), // ⌘⌥Space Finder search
        (kVK_Tab, cmdKey),              // ⌘Tab App switcher
        (kVK_UpArrow, controlKey),      // Ctrl↑ Mission Control
        (kVK_DownArrow, controlKey),    // Ctrl↓ Mission Control
        (kVK_LeftArrow, cmdKey),        // ⌘← Desktop
        (kVK_RightArrow, cmdKey),       // ⌘→ Desktop
    ]

    private func isSystemShortcut(keyCode: Int, modifiers: Int) -> Bool {
        for (sysKey, sysMod) in Self.systemShortcuts {
            if keyCode == sysKey && modifiers == sysMod {
                return true
            }
        }
        return false
    }

    private var defaultModifiers: Int {
        HotkeyManager.modifierFlagsToInt([.command, .shift])
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    // Hotkey section
                    settingsSection(
                        icon: "keyboard",
                        title: L("hotkey_title"),
                        description: L("hotkey_desc")
                    ) {
                        HStack(spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isRecording ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(isRecording ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor), lineWidth: 1)
                                    )

                                if isRecording {
                                    Text(L("hotkey_recording"))
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text(hotkeyManager.displayString)
                                        .font(.system(.body, design: .monospaced))
                                }
                            }
                            .frame(height: 36)
                            .frame(maxWidth: 200)
                            .onTapGesture { startRecording() }

                            if isRecording {
                                Button(L("hotkey_cancel")) { stopRecording() }
                                    .buttonStyle(.bordered)
                            } else {
                                Button(L("hotkey_reset")) {
                                    hotkeyManager.update(keyCode: kVK_ANSI_V, modifiers: defaultModifiers)
                                }
                                .buttonStyle(.bordered)
                            }
                        }

                        if isRecording {
                            Text(L("hotkey_hint"))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    // History limit section
                    settingsSection(
                        icon: "archivebox",
                        title: L("history_limit_title"),
                        description: L("history_limit_desc")
                    ) {
                        HStack(spacing: 8) {
                            TextField("", value: $maxItems, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                            Text(L("history_limit_items"))
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        }
                    }

                    // Language section
                    settingsSection(
                        icon: "globe",
                        title: L("language_title"),
                        description: L("language_desc")
                    ) {
                        Picker("", selection: $language) {
                            ForEach(AppLanguage.allCases, id: \.self) { lang in
                                Text(lang.displayName).tag(lang)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                        .labelsHidden()
                    }

                    // Launch at login section
                    settingsSection(
                        icon: "power",
                        title: L("launch_at_login_title"),
                        description: L("launch_at_login_desc")
                    ) {
                        Toggle(L("launch_at_login_toggle"), isOn: $launchAtLogin)
                            .toggleStyle(.switch)
                            .onChange(of: launchAtLogin) { _, newValue in
                                do {
                                    if newValue {
                                        try SMAppService.mainApp.register()
                                    } else {
                                        try SMAppService.mainApp.unregister()
                                    }
                                } catch {
                                    launchAtLogin = SMAppService.mainApp.status == .enabled
                                }
                            }
                    }

                    // Tips section
                    VStack(alignment: .leading, spacing: 10) {
                        Label(L("tips_title"), systemImage: "lightbulb")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                        tipRow(L("tip_modifier"))
                        tipRow(L("tip_global"))
                        tipRow(L("tip_default"))
                    }
                    .padding(.top, 4)
                }
                .padding(20)
            }
        }
        .frame(width: 420, height: 460)
        .background(KeyEventHandler(isRecording: $isRecording, keyCode: $recordedKeyCode, modifiers: $recordedModifiers) {
            if let key = recordedKeyCode, let mods = recordedModifiers {
                if isSystemShortcut(keyCode: key, modifiers: mods) {
                    showConflictAlert = true
                } else {
                    hotkeyManager.update(keyCode: key, modifiers: mods)
                }
            }
            stopRecording()
        })
        .alert(L("hotkey_conflict_title"), isPresented: $showConflictAlert) {
            Button(L("hotkey_conflict_ok")) {}
        } message: {
            Text(L("hotkey_conflict_msg"))
        }
    }

    // MARK: - Components

    private func settingsSection<Content: View>(
        icon: String,
        title: String,
        description: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline)
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func tipRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green)
                .padding(.top, 2)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func startRecording() {
        isRecording = true
        recordedKeyCode = nil
        recordedModifiers = nil
    }

    private func stopRecording() {
        isRecording = false
    }
}

// MARK: - Key Event Handler

private struct KeyEventHandler: NSViewRepresentable {
    @Binding var isRecording: Bool
    @Binding var keyCode: Int?
    @Binding var modifiers: Int?
    var onRecorded: () -> Void

    func makeNSView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView()
        view.onKeyDown = { event in
            guard isRecording else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let intMods = HotkeyManager.modifierFlagsToInt(flags)
            guard intMods != 0 else { return }
            keyCode = Int(event.keyCode)
            modifiers = intMods
            onRecorded()
        }
        return view
    }

    func updateNSView(_ nsView: KeyCaptureView, context: Context) {}
}

private class KeyCaptureView: NSView {
    var onKeyDown: ((NSEvent) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        onKeyDown?(event)
    }
}

#Preview {
    SettingsView()
}
