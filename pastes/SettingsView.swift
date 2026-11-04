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
    var captures: CaptureController?
    var onClose: () -> Void = {}
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
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    PastesGlassIcon(symbol: "slider.horizontal.3", tint: .blue, size: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("settings_title"))
                            .font(.system(size: 21, weight: .bold, design: .rounded))
                        Text(AppEnvironment.displayName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(L("version_label")) \(appVersion)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .pastesGlass(cornerRadius: 100)
                }
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(PastesGlassButtonStyle(compact: true))
                .foregroundStyle(.secondary)
                .accessibilityLabel(C("关闭设置", "Close settings"))
                .help(C("关闭设置（⌘W）", "Close settings (⌘W)"))
                .keyboardShortcut("w", modifiers: .command)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    generalSection
                    if let captures { CaptureSettingsView(controller: captures) }
                    shortcutSection
                    systemSection
                    updateSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 2)
                .padding(.bottom, 22)
            }
        }
        .font(.system(size: 13))
        .controlSize(.small)
        .buttonStyle(PastesGlassButtonStyle(compact: true))
        .tint(.blue)
        .background(PastesWindowBackground(cornerRadius: 28))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .frame(width: 540, height: 560)
        .ignoresSafeArea(.container, edges: .top)
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
        settingsSection(L("settings_general"), symbol: "slider.horizontal.3", tint: .blue) {
            settingsRow(L("history_limit_title"), subtitle: L("history_limit_compact_hint")) {
                HStack(spacing: 6) {
                    TextField("", value: $maxItems, format: .number)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(width: 64)
                        .pastesGlass(cornerRadius: 11)
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
                .padding(.horizontal, 18)
                .padding(.bottom, 15)
            }

            if let error = loginItemManager.errorMessage {
                groupNote(L("login_change_failed") + " " + error, isError: true)
            }
        }
    }

    // MARK: - Shortcut

    private var shortcutSection: some View {
        settingsSection(L("hotkey_title"), symbol: "keyboard", tint: .indigo) {
            settingsRow(L("hotkey_show_panel")) {
                HStack(spacing: 8) {
                    Button(action: startRecording) {
                        Text(isRecording ? L("hotkey_recording") : hotkeyManager.displayString)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .frame(minWidth: 88)
                    }
                    .buttonStyle(PastesGlassButtonStyle(prominence: isRecording ? .accent : .standard, compact: true))
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
        settingsSection(L("settings_system"), symbol: "hand.raised.fill", tint: .teal) {
            settingsRow(L("settings_auto_paste")) {
                HStack(spacing: 10) {
                    Text(L(accessibilityGranted ? "accessibility_status_granted" : "accessibility_status_required"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(accessibilityGranted ? Color.green : Color.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .pastesGlass(cornerRadius: 100, tint: accessibilityGranted ? .green.opacity(0.1) : nil)
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
        settingsSection(L("update_title"), symbol: "arrow.triangle.2.circlepath", tint: .purple) {
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
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            if let error = updateManager.startupError {
                groupNote(L("update_start_failed") + " " + error, isError: true)
            }
        }
    }

    // MARK: - Shared layout

    private func settingsSection<Content: View>(_ title: String, symbol: String, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                PastesGlassIcon(symbol: symbol, tint: tint, size: 32)
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 15)
            .padding(.bottom, 4)
            VStack(spacing: 0, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, 3)
        .pastesGlass(cornerRadius: 24)
        .shadow(color: .black.opacity(0.045), radius: 12, y: 5)
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
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var rowDivider: some View {
        Divider().opacity(0.28).padding(.horizontal, 18)
    }

    private func groupNote(_ text: String, isError: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(isError ? Color.red : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
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

struct KeyEventHandler: NSViewRepresentable {
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
            guard HotkeyManager.accepts(keyCode: Int(event.keyCode), modifiers: modifiersValue) else { return }
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

class KeyCaptureView: NSView {
    private static weak var activeRecorder: KeyCaptureView?
    var onKeyDown: ((NSEvent) -> Void)?
    var onCancel: (() -> Void)?
    private weak var previousResponder: NSResponder?
    private var localMonitor: Any?
    private var suspended = false

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
        if let other = Self.activeRecorder, other !== self {
            other.isRecording = false; other.onCancel?()
        }
        Self.activeRecorder = self
        if !suspended { HotkeyManager.beginRecording(); suspended = true }
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isRecording, event.window === self.window else { return event }
                self.keyDown(with: event)
                return nil
            }
        }
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
           let control = editor.delegate as? NSResponder {
            previousResponder = control
        } else {
            previousResponder = window.firstResponder
        }
        window.makeFirstResponder(self)
    }

    private func endCapture() {
        if Self.activeRecorder === self { Self.activeRecorder = nil }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        if suspended { suspended = false; HotkeyManager.endRecording() }
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
