//
//  SettingsView.swift
//  pastes
//
//  Created by hai on 2026/6/17.
//

import SwiftUI
import Carbon.HIToolbox
import ServiceManagement
import ApplicationServices

struct SettingsView: View {
    @ViewState private var isRecording = false
    @ViewState private var recordedKeyCode: Int?
    @ViewState private var recordedModifiers: Int?
    @ObservedObject private var hotkeyManager = HotkeyManager.shared
    @AppStorage("maxClipboardItems") private var maxItems = 20
    @AppStorage("appLanguage") private var language: AppLanguage = .zh
    @ObservedObject private var loginItemManager = LoginItemManager.shared
    @ViewState private var showConflictAlert = false
    @ViewState private var accessibilityGranted = PastePermission.isGranted
    @ObservedObject private var updateManager = UpdateManager.shared

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private static let systemShortcuts: [(Int, Int)] = [
        (kVK_ANSI_Q, cmdKey),
        (kVK_ANSI_W, cmdKey),
        (kVK_ANSI_C, cmdKey),
        (kVK_ANSI_V, cmdKey),
        (kVK_ANSI_X, cmdKey),
        (kVK_ANSI_Z, cmdKey),
        (kVK_ANSI_A, cmdKey),
        (kVK_ANSI_S, cmdKey),
        (kVK_ANSI_P, cmdKey),
        (kVK_ANSI_F, cmdKey),
        (kVK_ANSI_H, cmdKey),
        (kVK_ANSI_M, cmdKey),
        (kVK_ANSI_N, cmdKey),
        (kVK_ANSI_O, cmdKey),
        (kVK_ANSI_P, cmdKey | shiftKey),
        (kVK_ANSI_Z, cmdKey | shiftKey),
        (kVK_ANSI_3, cmdKey | shiftKey),
        (kVK_ANSI_4, cmdKey | shiftKey),
        (kVK_ANSI_5, cmdKey | shiftKey),
        (kVK_Space, cmdKey),
        (kVK_Space, cmdKey | optionKey),
        (kVK_Tab, cmdKey),
        (kVK_UpArrow, controlKey),
        (kVK_DownArrow, controlKey),
        (kVK_LeftArrow, cmdKey),
        (kVK_RightArrow, cmdKey),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("settings_title"))
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(L("version_label")) \(appVersion)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    generalSection
                    shortcutSection
                    systemSection
                    updateSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
        .font(.system(size: 13))
        .controlSize(.small)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 540, height: 560)
        .background(
            KeyEventHandler(
                isRecording: $isRecording,
                keyCode: $recordedKeyCode,
                modifiers: $recordedModifiers,
                onRecorded: finishRecording,
                onCancel: stopRecording
            )
            .frame(width: 0, height: 0)
        )
        .alert(L("hotkey_conflict_title"), isPresented: $showConflictAlert) {
            Button(L("hotkey_conflict_ok")) {}
        } message: {
            Text(hotkeyManager.registrationError ?? L("hotkey_conflict_msg"))
        }
        .onAppear(perform: refreshSystemStatus)
        .onDisappear(perform: stopRecording)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshSystemStatus()
        }
    }

    // MARK: - General

    private var generalSection: some View {
        settingsSection(L("settings_general")) {
            settingsRow(L("history_limit_title"), subtitle: L("history_limit_compact_hint")) {
                HStack(spacing: 6) {
                    TextField("", value: $maxItems, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 58)
                        .accessibilityLabel(L("history_limit_title"))
                    Text(L("history_limit_items"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .help(L("history_limit_desc"))

            rowDivider

            settingsRow(L("language_title")) {
                Picker(L("language_title"), selection: $language) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 116)
            }
            .help(L("language_desc"))

            rowDivider

            settingsRow(L("launch_at_login_title")) {
                HStack(spacing: 10) {
                    if loginItemManager.status == .requiresApproval {
                        Text(L("login_pending_status"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Toggle(L("launch_at_login_toggle"), isOn: Binding(
                        get: { loginItemManager.isRequested },
                        set: { loginItemManager.setEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
            }
            .help(L("launch_at_login_desc"))

            if loginItemManager.status == .requiresApproval {
                HStack(alignment: .center, spacing: 12) {
                    Text(L("login_approval_required"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(L("login_open_settings")) {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                    .fixedSize()
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }

            if let error = loginItemManager.errorMessage {
                groupNote(L("login_change_failed") + " " + error, isError: true)
            }
        }
    }

    // MARK: - Shortcut

    private var shortcutSection: some View {
        settingsSection(L("hotkey_title")) {
            settingsRow(L("hotkey_show_panel")) {
                HStack(spacing: 8) {
                    Button(action: startRecording) {
                        Text(isRecording ? L("hotkey_recording") : hotkeyManager.displayString)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(isRecording ? .secondary : .primary)
                            .padding(.horizontal, 10)
                            .frame(minWidth: 110, minHeight: 28)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(
                                        isRecording ? Color.primary.opacity(0.5) : Color(nsColor: .separatorColor).opacity(0.65),
                                        lineWidth: 0.5
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("hotkey_title"))
                    .help(L("hotkey_hint"))

                    if isRecording {
                        Button(L("hotkey_cancel"), action: stopRecording)
                    } else {
                        Button(L("hotkey_reset")) {
                            if !hotkeyManager.update(keyCode: kVK_ANSI_V, modifiers: HotkeyManager.defaultModifiers) {
                                showConflictAlert = true
                            }
                        }
                    }
                }
            }
            .help(L("hotkey_desc"))

            if isRecording {
                groupNote(L("tip_modifier"))
            } else {
                groupNote(L("hotkey_default_label") + " " + HotkeyManager.defaultDisplayString)
            }

            if let error = hotkeyManager.registrationError {
                groupNote(error, isError: true)
            }
        }
    }

    // MARK: - System

    private var systemSection: some View {
        settingsSection(L("settings_system")) {
            settingsRow(L("settings_auto_paste")) {
                HStack(spacing: 10) {
                    Text(L(accessibilityGranted ? "accessibility_status_granted" : "accessibility_status_required"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if !accessibilityGranted {
                        Button(L("accessibility_open_settings")) {
                            ClipboardMonitor.requestAccessibility()
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }

            if !accessibilityGranted {
                groupNote(L("accessibility_required"))
            }
        }
    }

    // MARK: - Updates

    private var updateSection: some View {
        settingsSection(L("update_title")) {
            HStack(alignment: .center, spacing: 16) {
                Text(L(AppEnvironment.isDevelopment ? "update_development_desc" : "update_desc"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(L("check_update_now")) {
                    updateManager.checkForUpdates()
                }
                .disabled(!updateManager.canCheckForUpdates)
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if let error = updateManager.startupError {
                groupNote(L("update_start_failed") + " " + error, isError: true)
            }
        }
    }

    // MARK: - Shared layout

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 3)

            VStack(spacing: 0, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
                )
        }
    }

    private func settingsRow<Control: View>(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            control().fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var rowDivider: some View {
        Divider().padding(.horizontal, 14)
    }

    private func groupNote(_ text: String, isError: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(isError ? Color.red : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.bottom, 11)
    }

    // MARK: - Actions

    private func refreshSystemStatus() {
        loginItemManager.refresh()
        accessibilityGranted = PastePermission.isGranted
        if accessibilityGranted { PasteFeedback.shared.needsPermission = false }
    }

    private func isSystemShortcut(keyCode: Int, modifiers: Int) -> Bool {
        Self.systemShortcuts.contains { $0.0 == keyCode && $0.1 == modifiers }
    }

    private func startRecording() {
        guard !isRecording else { return }
        recordedKeyCode = nil
        recordedModifiers = nil
        isRecording = true
    }

    private func finishRecording() {
        if let key = recordedKeyCode, let modifiers = recordedModifiers {
            if isSystemShortcut(keyCode: key, modifiers: modifiers)
                || !hotkeyManager.update(keyCode: key, modifiers: modifiers) {
                showConflictAlert = true
            }
        }
        stopRecording()
    }

    private func stopRecording() {
        isRecording = false
    }
}

// MARK: - Shortcut capture

private struct KeyEventHandler: NSViewRepresentable {
    @Binding var isRecording: Bool
    @Binding var keyCode: Int?
    @Binding var modifiers: Int?
    var onRecorded: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> KeyCaptureView {
        KeyCaptureView()
    }

    func updateNSView(_ view: KeyCaptureView, context: Context) {
        view.onKeyDown = { event in
            guard isRecording else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let modifiersValue = HotkeyManager.modifierFlagsToInt(flags)
            guard modifiersValue != 0 else { return }
            keyCode = Int(event.keyCode)
            modifiers = modifiersValue
            onRecorded()
        }
        view.onCancel = onCancel
        view.isRecording = isRecording
    }

    static func dismantleNSView(_ view: KeyCaptureView, coordinator: ()) {
        view.isRecording = false
    }
}

private class KeyCaptureView: NSView {
    var onKeyDown: ((NSEvent) -> Void)?
    var onCancel: (() -> Void)?
    private weak var previousResponder: NSResponder?

    var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            if isRecording { beginCapture() }
            else { endCapture() }
        }
    }

    override var acceptsFirstResponder: Bool { isRecording }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if isRecording { beginCapture() }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { endCapture() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func beginCapture() {
        guard let window, window.firstResponder !== self else { return }
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
           let control = editor.delegate as? NSResponder {
            previousResponder = control
        } else {
            previousResponder = window.firstResponder
        }
        window.makeFirstResponder(self)
    }

    private func endCapture() {
        if let window, window.firstResponder === self {
            if !window.makeFirstResponder(previousResponder) {
                window.makeFirstResponder(nil)
            }
        }
        previousResponder = nil
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == UInt16(kVK_Escape) {
            onCancel?()
        } else {
            onKeyDown?(event)
        }
    }
}
