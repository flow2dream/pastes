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
    @State private var hoveredButton: String?
    private let updateManager = UpdateManager.shared
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
            // Header
            VStack(spacing: 6) {
                Image(systemName: "clipboard.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.linearGradient(
                        colors: [.accentColor, .accentColor.opacity(0.6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                Text(L("settings_title"))
                    .font(.title3.bold())
            }
            .padding(.top, 20)
            .padding(.bottom, 16)

            ScrollView {
                VStack(spacing: 14) {
                    // Hotkey section
                    settingsCard(icon: "keyboard.fill", title: L("hotkey_title"), accent: .blue) {
                        Text(L("hotkey_desc"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 6)

                        HStack(spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isRecording
                                        ? Color.accentColor.opacity(0.1)
                                        : Color(nsColor: .controlBackgroundColor))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(
                                                isRecording
                                                    ? Color.accentColor.opacity(0.5)
                                                    : Color(nsColor: .separatorColor).opacity(0.5),
                                                lineWidth: 1
                                            )
                                    )

                                if isRecording {
                                    HStack(spacing: 6) {
                                        Image(systemName: "mic.fill")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.red)
                                        Text(L("hotkey_recording"))
                                            .font(.system(.body, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                } else {
                                    Text(hotkeyManager.displayString)
                                        .font(.system(.body, design: .monospaced))
                                }
                            }
                            .frame(height: 34)
                            .frame(maxWidth: 200)
                            .onTapGesture { startRecording() }

                            if isRecording {
                                Button(L("hotkey_cancel")) { stopRecording() }
                                    .buttonStyle(.bordered)
                                    .brightness(hoveredButton == "cancel" ? 0.1 : 0)
                                    .scaleEffect(hoveredButton == "cancel" ? 1.03 : 1.0)
                                    .animation(.easeInOut(duration: 0.15), value: hoveredButton)
                                    .onHover { hoveredButton = $0 ? "cancel" : nil }
                            } else {
                                Button(L("hotkey_reset")) {
                                    hotkeyManager.update(keyCode: kVK_ANSI_V, modifiers: defaultModifiers)
                                }
                                .buttonStyle(.bordered)
                                .brightness(hoveredButton == "reset" ? 0.1 : 0)
                                .scaleEffect(hoveredButton == "reset" ? 1.03 : 1.0)
                                .animation(.easeInOut(duration: 0.15), value: hoveredButton)
                                .onHover { hoveredButton = $0 ? "reset" : nil }
                            }
                        }

                        if isRecording {
                            Text(L("hotkey_hint"))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 2)
                        }
                    }

                    // History limit section
                    settingsCard(icon: "archivebox.fill", title: L("history_limit_title"), accent: .orange) {
                        Text(L("history_limit_desc"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 6)

                        HStack(spacing: 8) {
                            TextField("", value: $maxItems, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 72)
                            Text(L("history_limit_items"))
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        }
                    }

                    // Language section
                    settingsCard(icon: "globe", title: L("language_title"), accent: .purple) {
                        Text(L("language_desc"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 6)

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
                    settingsCard(icon: "power", title: L("launch_at_login_title"), accent: .green) {
                        HStack {
                            Text(L("launch_at_login_desc"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Toggle("", isOn: $launchAtLogin)
                                .toggleStyle(.switch)
                                .labelsHidden()
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
                    }

                    // Update section
                    settingsCard(icon: "arrow.triangle.2.circlepath", title: L("update_title"), accent: .teal) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("update_desc"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(L("version_label")) \(appVersion)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button {
                                updateManager.checkForUpdates()
                            } label: {
                                Label(L("check_update_now"), systemImage: "arrow.down.circle")
                                    .font(.subheadline)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.teal)
                            .brightness(hoveredButton == "update" ? 0.1 : 0)
                            .scaleEffect(hoveredButton == "update" ? 1.03 : 1.0)
                            .animation(.easeInOut(duration: 0.15), value: hoveredButton)
                            .onHover { hoveredButton = $0 ? "update" : nil }
                        }
                    }

                    // Tips section
                    VStack(alignment: .leading, spacing: 8) {
                        Label(L("tips_title"), systemImage: "lightbulb.max")
                            .font(.subheadline.bold())
                            .foregroundStyle(.orange)
                        tipRow(L("tip_modifier"))
                        tipRow(L("tip_global"))
                        tipRow(L("tip_default"))
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.orange.opacity(0.12), lineWidth: 1)
                    )
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 20)
            }
        }
        .frame(width: 420, height: 480)
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

    private func settingsCard<Content: View>(
        icon: String,
        title: String,
        accent: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 28, height: 28)
                    .background(accent.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text(title)
                    .font(.system(.subheadline, weight: .semibold))
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 1)
        )
    }

    private func tipRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.green)
                .padding(.top, 3)
            Text(text)
                .font(.caption)
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
