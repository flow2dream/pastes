//
//  pastesApp.swift
//  pastes
//
//  Created by hai on 2026/6/17.
//

import SwiftUI
import SwiftData

@main
struct pastesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // All UI is managed by PanelManager via AppDelegate
        WindowGroup {
            EmptyView()
        }
        .windowResizability(.contentSize)
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
        let modelContainer: ModelContainer
        do {
            let schema = Schema([ClipboardItem.self])
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            modelContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Fallback: try deleting corrupted store and retry
            let storeURL = URL.applicationSupportDirectory.appendingPathComponent("default.store")
            try? FileManager.default.removeItem(at: storeURL)
            do {
                let schema = Schema([ClipboardItem.self])
                let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
                modelContainer = try ModelContainer(for: schema, configurations: [config])
            } catch {
                fatalError("Failed to create ModelContainer: \(error)")
            }
        }

        panelManager = PanelManager(modelContainer: modelContainer)

        // Request accessibility permission on launch
        ClipboardMonitor.requestAccessibility()

        hotkeyManager.register { [weak self] in
            self?.panelManager.toggle(atMouse: true)
        }

        // Close any stray windows (including SwiftUI WindowGroup)
        DispatchQueue.main.async {
            NSApp.windows.forEach { window in
                window.orderOut(nil)
                window.isExcludedFromWindowsMenu = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.windows.forEach { window in
                if window !== self.panelManager.panelWindow {
                    window.orderOut(nil)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.unregister()
    }
}
