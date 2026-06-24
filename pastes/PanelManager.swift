//
//  PanelManager.swift
//  pastes
//
//  Created by hai on 2026/6/17.
//

import AppKit
import SwiftUI
import SwiftData

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
    private let modelContainer: ModelContainer
    private var previousApp: NSRunningApplication?
    private var globalMonitor: Any?
    var isPanelPinned = false

    var panelWindow: NSWindow? { panel }

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        super.init()
        setupStatusItem()
        setupPanel()
    }

    // MARK: - Status Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        let customButton = StatusButton(frame: button.bounds)
        customButton.isBordered = false
        customButton.image = NSImage(systemSymbolName: "clipboard.fill", accessibilityDescription: "Pastes")
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
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 460)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
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
            onOpenSettings: { [weak self] in
                self?.openSettings()
            },
            onPaste: { [weak self] in
                self?.handlePaste()
            },
            onTogglePin: { [weak self] in
                self?.isPanelPinned.toggle()
                return self?.isPanelPinned ?? false
            }
        )
        .modelContainer(modelContainer)

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 520)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.title = "Pastes"
        panel.titlebarAppearsTransparent = true
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
        panel.contentView?.layer?.cornerRadius = 1
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
    }

    func toggle(atMouse: Bool = false) {
        guard let panel else { return }
        if panel.isVisible {
            hidePanel()
        } else {
            // Capture frontmost app before we take focus
            let ourPID = ProcessInfo.processInfo.processIdentifier
            if let current = NSWorkspace.shared.frontmostApplication, current.processIdentifier != ourPID {
                previousApp = current
            }
            showPanel(atMouse: atMouse)
        }
    }

    private func showPanel(atMouse: Bool = false) {
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
    }

    private func handlePaste() {
        hidePanel()

        // Activate the previous app
        if let app = previousApp {
            app.activate()
        }
        NSApp.hide(nil)

        // Give time for focus to fully switch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            ClipboardMonitor.simulatePaste()
        }
    }

    private func hidePanel() {
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
