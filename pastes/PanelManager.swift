//
//  PanelManager.swift
//  pastes
//
//  Created by hai on 2026/6/17.
//

import AppKit
import SwiftUI

// MARK: - Custom Status Bar Button

private class StatusButton: NSButton {
    var onLeftClick: (() -> Void)?
    var onRightClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            onRightClick?()
        } else {
            onLeftClick?()
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        onRightClick?()
    }
}

// MARK: - Panel Manager

final class PanelManager: NSObject {
    private var panel: NSPanel?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private let store: ClipboardStore
    private var previousApp: NSRunningApplication?
    private var globalMonitor: Any?
    private let workspaceNotifications = NSWorkspace.shared.notificationCenter
    private var activationObserver: NSObjectProtocol?
    private var pendingPaste: (id: UUID, targetPID: pid_t)?
    var isPanelPinned = false

    var panelWindow: NSWindow? { panel }

    init(store: ClipboardStore) {
        self.store = store
        super.init()
        trackActiveApplication()
        setupStatusItem()
        setupPanel()
    }

    // MARK: - Status Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        let customButton = StatusButton(frame: button.bounds)
        customButton.isBordered = false
        customButton.image = NSImage(systemSymbolName: "clipboard.fill", accessibilityDescription: AppEnvironment.displayName)
        customButton.imagePosition = .imageOnly
        customButton.onLeftClick = { [weak self] in
            self?.toggle()
        }
        customButton.onRightClick = { [weak self] in
            self?.showContextMenu()
        }

        button.addSubview(customButton)
        customButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            customButton.topAnchor.constraint(equalTo: button.topAnchor),
            customButton.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            customButton.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            customButton.trailingAnchor.constraint(equalTo: button.trailingAnchor)
        ])
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let settingsItem = NSMenuItem(title: L("settings_title") + "...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: L("quit_app"), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc func openSettings() {
        hidePanel()
        if let settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }

        let settingsView = SettingsView()
        let hostingView = NSHostingView(rootView: settingsView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 540, height: 560)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = L("settings_title")
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        self.settingsWindow = window
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Panel

    private func setupPanel() {
        let contentView = ContentView(
            store: store,
            onOpenSettings: { [weak self] in
                self?.openSettings()
            },
            onPaste: { [weak self] in
                self?.handlePaste()
            },
            onTogglePin: { [weak self] in
                self?.isPanelPinned.toggle()
                return self?.isPanelPinned ?? false
            },
            onDismiss: { [weak self] in
                self?.hidePanel()
            }
        )

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 520, height: 540)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 540),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.title = AppEnvironment.displayName
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .windowBackgroundColor
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 12
        panel.contentView?.layer?.masksToBounds = true

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            guard !self.isPanelPinned else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if !panel.isKeyWindow && !panel.isMainWindow {
                    self.hidePanel()
                }
            }
        }

        self.panel = panel
    }

    deinit {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = activationObserver {
            workspaceNotifications.removeObserver(observer)
        }
    }

    private func trackActiveApplication() {
        if let current = NSWorkspace.shared.frontmostApplication {
            rememberPasteTarget(current)
        }
        activationObserver = workspaceNotifications.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                self?.rememberPasteTarget(app)
            }
        }
    }

    private func rememberPasteTarget(_ app: NSRunningApplication) {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !app.isTerminated else { return }
        previousApp = app
        // A user switching elsewhere during the delay cancels this request.
        if let pendingPaste, pendingPaste.targetPID != app.processIdentifier {
            PasteTrace.record("paste_cancelled", details: ["reason": "other_app_activated", "expectedPID": pendingPaste.targetPID, "activatedPID": app.processIdentifier])
            self.pendingPaste = nil
        }
    }

    func toggle(atMouse: Bool = false) {
        guard let panel else { return }
        if panel.isVisible {
            hidePanel()
        } else {
            // Capture frontmost app before we take focus
            if let current = NSWorkspace.shared.frontmostApplication {
                rememberPasteTarget(current)
            }
            showPanel(atMouse: atMouse)
        }
    }

    private func showPanel(atMouse: Bool = false) {
        pendingPaste = nil
        guard let panel else { return }
        let panelSize = panel.frame.size
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero

        let x: CGFloat
        let y: CGFloat

        if atMouse {
            let mouse = NSEvent.mouseLocation
            x = min(max(mouse.x - panelSize.width / 2, screenFrame.minX), screenFrame.maxX - panelSize.width)
            y = max(mouse.y - panelSize.height - 10, screenFrame.minY)
        } else {
            guard let button = statusItem?.button else { return }
            let buttonRect = button.window?.convertToScreen(button.frame) ?? .zero
            x = min(buttonRect.midX - panelSize.width / 2, screenFrame.maxX - panelSize.width)
            y = max(buttonRect.minY - panelSize.height - 4, screenFrame.minY)
        }

        panel.setFrameOrigin(NSPoint(x: x, y: y))

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        PasteTrace.record("panel_shown", details: ["visible": panel.isVisible, "appHidden": NSApp.isHidden, "isKey": panel.isKeyWindow])
    }

    private func handlePaste() {
        PasteTrace.record("paste_requested")
        guard PastePermission.isGranted else {
            PasteFeedback.shared.needsPermission = true
            PasteTrace.record("paste_blocked", details: ["reason": "event_posting_not_allowed"])
            return
        }
        PasteFeedback.shared.needsPermission = false
        hidePanel()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let current = NSWorkspace.shared.frontmostApplication else {
            PasteTrace.record("paste_cancelled", details: ["reason": "no_frontmost_app"])
            return
        }
        if current.processIdentifier != ownPID {
            rememberPasteTarget(current)
        }
        guard let target = previousApp, !target.isTerminated else {
            PasteTrace.record("paste_cancelled", details: ["reason": "no_live_target", "frontPID": current.processIdentifier])
            return
        }
        let requestID = UUID()
        let targetPID = target.processIdentifier
        pendingPaste = (requestID, targetPID)
        PasteTrace.record("paste_target", details: ["frontPID": current.processIdentifier, "targetPID": targetPID, "ownPID": ownPID])

        if current.processIdentifier == ownPID {
            // Return from our panel once. If activation fails, do not retry or paste.
            guard target.activate() else {
                PasteTrace.record("paste_cancelled", details: ["reason": "target_activation_failed", "targetPID": targetPID])
                pendingPaste = nil
                return
            }
            NSApp.hide(nil)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.pendingPaste?.id == requestID else {
                PasteTrace.record("paste_cancelled", details: ["reason": "request_no_longer_pending"])
                return
            }
            self.pendingPaste = nil
            guard !target.isTerminated,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else {
                PasteTrace.record("paste_cancelled", details: ["reason": "target_not_frontmost", "targetPID": targetPID, "frontPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1])
                return
            }
            PasteTrace.record("paste_target_ready", details: ["targetPID": targetPID])
            ClipboardMonitor.simulatePaste()
        }
    }

    private func hidePanel() {
        PasteTrace.record("panel_hidden")
        pendingPaste = nil
        panel?.orderOut(nil)
    }
}

// MARK: - NSWindowDelegate

extension PanelManager: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow {
            settingsWindow = nil
        }
    }
}
