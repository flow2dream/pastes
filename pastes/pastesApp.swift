//
//  pastesApp.swift
//  pastes
//
//  Created by hai on 2026/6/17.
//

import SwiftUI
import OSLog

@main
@MainActor
enum PastesBootstrap {
    static func main() {
        if AppEnvironment.isDevelopment {
            // SwiftUI otherwise creates its own NSApplication subclass and
            // ignores NSPrincipalClass. Keep the scene/delegate lifecycle while
            // observing events before application-local monitors.
            let application = PastesApplication.shared
            withExtendedLifetime(application) { pastesApp.main() }
        } else {
            pastesApp.main()
        }
    }
}

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
    private var clipboardSession: ClipboardSession?
    private var captures: CaptureController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        if AppEnvironment.isDevelopment, let application = NSApp {
            let runtime = NSStringFromClass(type(of: application))
            Logger(subsystem: "com.pastes.capture", category: "pinch")
                .notice("APP INPUT launch runtime=\(runtime, privacy: .public)")
        }
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

        let session = ClipboardSession(store: store)
        clipboardSession = session
        do {
            let library = try CaptureLibrary(directory: AppEnvironment.storageURL.deletingLastPathComponent().appendingPathComponent("CaptureLibrary", isDirectory: true))
            let controller = CaptureController(library: library, session: session)
            captures = controller
            NSApp.servicesProvider = controller
            controller.start()
        } catch {
            session.errorMessage = error.localizedDescription
        }
        panelManager = PanelManager(store: store, session: session, captures: captures)
        session.start()
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
        captures?.stop()
        clipboardSession?.stop()
    }
}
