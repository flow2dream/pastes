//
//  pastesApp.swift
//  pastes
//
//  Created by hai on 2026/6/17.
//

import SwiftUI

@main
struct pastesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // PanelManager owns every window; a WindowGroup would reopen an empty
        // window whenever Launch Services activates the development app.
        Settings {
            EmptyView()
        }
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotkeyManager = HotkeyManager.shared
    private var panelManager: PanelManager!

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Set app language before any framework loads
        let lang = UserDefaults.standard.string(forKey: "appLanguage") ?? "zh_CN"
        UserDefaults.standard.set([lang], forKey: "AppleLanguages")

        // Set accessory policy BEFORE the WindowGroup window appears
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        PasteTrace.captureLaunch()
        let store: ClipboardStore
        do {
            store = try ClipboardStore(url: AppEnvironment.storageURL)
        } catch {
            let alert = NSAlert()
            alert.messageText = L("storage_error_title")
            alert.informativeText = L("storage_open_error") + "\n" + error.localizedDescription
            alert.alertStyle = .critical
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        panelManager = PanelManager(store: store)
        if PasteTrace.isEnabled {
            panelManager.isPanelPinned = true
        }

        // Start the release update schedule at launch, even if Settings stays closed.
        _ = UpdateManager.shared

        // Keep development launches quiet; request permission when paste is used.
        if !AppEnvironment.isDevelopment {
            ClipboardMonitor.requestAccessibility()
        }

        hotkeyManager.register { [weak self] in
            self?.panelManager.toggle(atMouse: true)
        }

        if AppEnvironment.isDevelopment {
            DispatchQueue.main.async { [weak self] in
                self?.panelManager.toggle()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.unregister()
    }
}
