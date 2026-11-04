import AppKit
import Combine
import UniformTypeIdentifiers
import Carbon.HIToolbox

@MainActor
final class CaptureController: NSObject, ObservableObject {
    let library: CaptureLibrary
    let session: ClipboardSession
    private let legacyInbox: CaptureInbox
    private let watcher = CaptureWatcher()
    private let defaults: UserDefaults
    private let screenshotCapture: () async throws -> [ScreenshotFrame]
    private var importCount = 0
    private var arrivalSubscription: AnyCancellable?
    private var configurationTimer: Timer?
    private var watchedFolder: URL?
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var lineRevealed = false
    @Published var copiedCaptureID: UUID?
    @Published private(set) var liftingCaptureIDs: Set<UUID> = []
    @Published private(set) var enabled: Bool
    @Published private(set) var watchScreenshots: Bool
    @Published private(set) var hideImagesInHistory: Bool
    @Published private(set) var maximumItems: Int
    @Published private(set) var usesCustomLimit: Bool
    @Published private(set) var adaptiveRetention: Bool
    @Published private(set) var adaptiveWidth: CGFloat = 1440
    var adaptiveCapacity: Int { CaptureLineLayout.adaptiveCapacity(width: adaptiveWidth) }
    @Published private(set) var copiedImages: Bool
    @Published private(set) var busy = false
    @Published private(set) var screenshotActive = false
    let screenshotShortcut = HotkeyManager(prefix: "nativeScreenshotShortcut", keyCode: kVK_ANSI_S,
        modifiers: controlKey | optionKey | (AppEnvironment.isDevelopment ? shiftKey : 0), signature: 0x50534353)
    var shelf: CaptureShelfPanel?
    var onShelfWillShow: (() -> Void)?
    var onScreenshotWillBegin: (() -> Void)?
    lazy var screenshot = NativeScreenshot(capture: screenshotCapture, onActive: { [weak self] active in
        self?.screenshotActive = active
        self?.shelf?.setScreenshotActive(active)
    }, onCaptured: { [weak self] data, origin in
        try self?.acceptScreenshot(data, origin: origin)
    }, onError: { [weak self] error in
        self?.errorMessage = error.localizedDescription
        let alert = NSAlert()
        alert.messageText = C("截图未完成", "Screenshot not completed")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: C("好", "OK"))
        if case NativeScreenshotError.permission = error {
            alert.addButton(withTitle: C("打开系统设置", "Open System Settings"))
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }, onPinned: { [weak self] data, origin in
        guard let self else { return }
        try self.pinScreenshot(data, origin: origin)
    })

    func takeScreenshot() {
        guard !screenshotActive else { return }
        onScreenshotWillBegin?()
        screenshot.begin()
    }

    @discardableResult
    func pinScreenshot(_ data: Data, origin: CGRect) throws -> CaptureReferencePanel {
        guard NSImage(data: data) != nil else { throw CaptureError.invalidMedia }
        var pendingItem: CaptureItem?
        return try editors.hold(data: data, title: C("固定截图", "Pinned screenshot"), origin: origin,
            onCloseToShelf: { [weak self] updated, currentFrame in
                guard let self else { throw CaptureError.invalidMedia }
                _ = try self.acceptScreenshot(updated, origin: currentFrame, copyToClipboard: false,
                    pendingItem: &pendingItem)
            }, onDestroy: { [weak self] in
                guard let pending = pendingItem else { return }
                guard let self else { throw CaptureError.invalidMedia }
                try self.library.remove(pending.id)
            })
    }

    @discardableResult
    func acceptScreenshot(_ data: Data, origin: CGRect, copyToClipboard: Bool = true) throws -> CaptureItem {
        var pendingItem: CaptureItem?
        return try acceptScreenshot(data, origin: origin, copyToClipboard: copyToClipboard, pendingItem: &pendingItem)
    }

    private func acceptScreenshot(_ data: Data, origin: CGRect, copyToClipboard: Bool,
                                  pendingItem: inout CaptureItem?) throws -> CaptureItem {
        // Preserve the captured source rectangle and never route through an external app.
        if !enabled { setEnabled(true) }
        let title = pendingItem?.title ?? C("截图", "Screenshot") + " " + Date().formatted(date: .omitted, time: .standard) + ".png"
        let retrying = pendingItem != nil
        try session.store.addEditedImage(data, limit: session.limit) { historyID in
            // The media manifest commits before SQLite. Retain its new revision
            // immediately so a failed SQLite commit can retry this same image.
            if let pending = pendingItem {
                pendingItem = try library.overwriteImage(id: pending.id, expectedDigest: pending.digest,
                    data: data, historyID: historyID)
            } else {
                pendingItem = try library.importImage(data, title: title, historyID: historyID, forceNew: true, origin: origin)
            }
        }
        guard let captured = pendingItem else { throw CaptureError.invalidMedia }
        if retrying { library.animateArrival(captured.id, origin: origin) }
        guard copyToClipboard else { return captured }
        do { _ = try session.copy(ClipboardItem(content: title, imageData: data)) }
        catch {
            // The image is safely stored even if clipboard ownership was lost.
            errorMessage = C("截图已保存到图片架，但复制到剪贴板失败：", "Screenshot saved to the shelf, but copying failed: ") + error.localizedDescription
        }
        return captured
    }
    lazy var editors = CaptureEditors(onSaved: { [weak self] url in
        guard let self else { return }
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
            let data = try Data(contentsOf: url)
            try self.session.store.addEditedImage(data, limit: self.session.limit) { historyID in
                _ = try self.library.importImage(data, title: C("编辑副本.png", "Edited copy.png"), historyID: historyID, forceNew: true)
            }
        } else { _ = try await self.importFile(url) }
    }, onError: { [weak self] error in self?.errorMessage = error.localizedDescription }, onReferenceEditingChanged: { [weak self] active in
        self?.screenshotActive = active
        self?.shelf?.setScreenshotActive(active)
    })

    init(library: CaptureLibrary, session: ClipboardSession, defaults: UserDefaults = .standard,
         screenshotCapture: @escaping () async throws -> [ScreenshotFrame] = NativeScreenshot.captureDisplays) {
        self.library = library; self.session = session; self.defaults = defaults
        self.screenshotCapture = screenshotCapture
        legacyInbox = CaptureInbox(folder: library.directory.deletingLastPathComponent().appendingPathComponent("CaptureInbox"), defaults: defaults)
        enabled = defaults.object(forKey: "captureShelfEnabled") as? Bool ?? false
        watchScreenshots = defaults.object(forKey: "captureWatchScreenshots") as? Bool ?? false
        copiedImages = defaults.object(forKey: "captureCopiedImages") as? Bool ?? true
        hideImagesInHistory = defaults.object(forKey: "captureHideImagesInHistory") as? Bool ?? true
        let savedMaximum = max(0, defaults.object(forKey: "captureMaximumItems") as? Int ?? 20)
        maximumItems = savedMaximum
        usesCustomLimit = defaults.bool(forKey: "captureUsesCustomLimit") || !CaptureRetentionInput.presets.contains(savedMaximum)
        adaptiveRetention = defaults.bool(forKey: "captureAdaptiveRetention")
        super.init()
        adaptiveWidth = NSScreen.main?.visibleFrame.width ?? 1440
        perform { try library.setMaximumItems(adaptiveRetention ? adaptiveCapacity : maximumItems, includingPins: adaptiveRetention) }
    }
    func start() {
        if !screenshotShortcut.register(onTrigger: { [weak self] in self?.takeScreenshot() }) {
            errorMessage = screenshotShortcut.registrationError
        }
        // Retired versions may have left a journal and redirected system captures.
        // Restore only settings they still own; never enable capture takeover again.
        legacyInbox.restore()
        session.onImage = { [weak self] data, id in
            guard let self, enabled, copiedImages else { return }
            perform { _ = try self.library.importImage(data, title: C("复制的图片", "Copied image"), historyID: id, origin: self.session.copiedImageBounds) }
        }
        shelf = CaptureShelfPanel(controller: self)
        shelf?.setEnabled(enabled)
        arrivalSubscription = library.$latestArrival.dropFirst().compactMap { $0 }
            .compactMap { [weak self] arrival in self?.shelf?.arrivalRequest(for: arrival) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] request in
                guard let self, self.enabled,
                      self.library.visibleItems.contains(where: { $0.id == request.arrival.itemID }) else { return }
                self.shelf?.showForArrival(request)
            }
        restartWatcher()
        configurationTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.enabled else { return }
                if self.watchScreenshots && self.watchedFolder != CaptureInbox.screenshotFolder {
                    self.restartWatcher()
                }
            }
        }
    }
    func stop() { screenshot.cancel(); screenshotShortcut.unregister(); arrivalSubscription = nil; configurationTimer?.invalidate(); configurationTimer = nil; watcher.stop(); shelf?.stop(); editors.closeAll() }
    func setEnabled(_ value: Bool) {
        enabled = value; defaults.set(value, forKey: "captureShelfEnabled")
        shelf?.setEnabled(value); restartWatcher()
    }
    func setWatching(_ value: Bool) {
        watchScreenshots = value; defaults.set(value, forKey: "captureWatchScreenshots"); restartWatcher()
    }
    func setCopiedImages(_ value: Bool) {
        copiedImages = value; defaults.set(value, forKey: "captureCopiedImages")
    }
    func setHideImagesInHistory(_ value: Bool) {
        hideImagesInHistory = value; defaults.set(value, forKey: "captureHideImagesInHistory")
    }
    func selectCustomLimit() {
        applyMaximumItems(maximumItems > 0 ? maximumItems : 20, custom: true)
    }
    func setAdaptiveRetention() {
        perform {
            try library.setMaximumItems(adaptiveCapacity, includingPins: true)
            adaptiveRetention = true
            defaults.set(true, forKey: "captureAdaptiveRetention")
        }
    }
    func updateShelfWidth(_ width: CGFloat) {
        guard width > 0, width != adaptiveWidth else { return }
        perform {
            if adaptiveRetention {
                try library.setMaximumItems(CaptureLineLayout.adaptiveCapacity(width: width), includingPins: true)
            }
            adaptiveWidth = width
        }
    }
    func setCustomMaximumItems(_ value: Int) {
        guard value > 0 else { return }
        applyMaximumItems(value, custom: true)
    }
    func setMaximumItems(_ value: Int) {
        applyMaximumItems(value, custom: !CaptureRetentionInput.presets.contains(value))
    }
    private func applyMaximumItems(_ value: Int, custom: Bool) {
        perform {
            try library.setMaximumItems(value)
            maximumItems = library.maximumItems
            adaptiveRetention = false
            defaults.set(false, forKey: "captureAdaptiveRetention")
            usesCustomLimit = custom
            defaults.set(custom, forKey: "captureUsesCustomLimit")
            defaults.set(maximumItems, forKey: "captureMaximumItems")
        }
    }
    private func restartWatcher() {
        watcher.stop()
        watchedFolder = nil
        guard enabled, watchScreenshots else { return }
        let folder = CaptureInbox.screenshotFolder
        watchedFolder = folder
        // Never watch a different application's private inbox, especially the running Tendedero.
        if folder.path.contains("/Library/Application Support/") && !folder.path.hasPrefix(legacyInbox.folder.path) {
            errorMessage = C("系统截图正保存到其他应用的目录。请关闭该应用的截图接管，或手动导入文件。", "Screenshots are going to another app's private folder. Disable its takeover or import files manually.")
            return
        }
        watcher.start(folder: folder, acceptsAllMedia: false, onFile: { [weak self] url in
            guard let self else { return }; _ = try await self.importFile(url)
        }, onError: { [weak self] error in self?.errorMessage = error.localizedDescription })
    }
    @discardableResult
    func importFile(_ url: URL, origin: CGRect? = nil) async throws -> CaptureItem {
        importCount += 1; busy = true
        defer { importCount -= 1; busy = importCount > 0 }
        let item = try await library.importMedia(url, origin: origin)
        if item.kind == .image {
            let data = try Data(contentsOf: library.url(for: item))
            let id = try session.store.addImage(data, limit: session.limit)
            try library.link(item.id, historyID: id)
        }
        return item
    }
    func importFiles(_ urls: [URL], pinned: Bool = false, origin: CGRect? = nil) {
        Task {
            for url in urls {
                do {
                    let item = try await importFile(url, origin: origin)
                    if pinned && !item.isPinned { try library.togglePin(item.id) }
                } catch { errorMessage = error.localizedDescription }
            }
        }
    }
    @objc func addToCaptureShelf(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        var urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if urls.isEmpty, let paths = pasteboard.propertyList(forType: .init("NSFilenamesPboardType")) as? [String] {
            urls = paths.map { URL(fileURLWithPath: $0) }
        }
        guard !urls.isEmpty else { error.pointee = C("未找到可导入的文件。", "No files to import.") as NSString; return }
        if !enabled { setEnabled(true) }
        importFiles(urls, pinned: true)
        shelf?.show()
    }
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie]; panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] result in
            guard result == .OK else { return }; self?.importFiles(panel.urls)
        }
    }
    func copy(_ item: CaptureItem) {
        perform {
            let url = library.url(for: item)
            if item.kind == .image {
                _ = try session.copy(ClipboardItem(content: item.title, imageData: Data(contentsOf: url)))
            } else { try session.copyFile(url) }
            notice = C("已复制", "Copied")
            copiedCaptureID = item.id
            library.animateArrival(item.id, origin: shelf?.screenRect(for: item.id))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                if self?.copiedCaptureID == item.id { self?.copiedCaptureID = nil }
            }
        }
    }
    func remove(_ item: CaptureItem) { perform { try library.remove(item.id) } }
    func removeSide(of item: CaptureItem, side: CaptureLibrary.RemovalSide) {
        perform { try library.remove(ids: library.removalIDs(relativeTo: item.id, side: side)) }
    }
    func undo() { perform { try library.undo() } }
    func pin(_ item: CaptureItem) { perform { try library.togglePin(item.id) } }
    func hold(_ requested: CaptureItem) {
        guard !liftingCaptureIDs.contains(requested.id),
              let item = library.shelfItems.first(where: { $0.id == requested.id }) else { return }
        guard item.kind == .image else {
            editors.hold(library.url(for: item), title: item.title, movie: true)
            return
        }
        perform {
            let original = try Data(contentsOf: library.url(for: item))
            guard let image = NSImage(data: original) else { throw CaptureError.invalidMedia }
            let source = lineRevealed ? shelf?.screenRect(for: item.id)?.insetBy(dx: 4, dy: 4) : nil
            let destination = source.flatMap { source -> CGRect? in
                guard let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: source.midX, y: source.midY)) }) else { return nil }
                let size = CaptureEditors.referenceSize(image: image.size)
                return CGRect(x: screen.visibleFrame.midX - size.width / 2,
                              y: screen.visibleFrame.midY - size.height / 2, width: size.width, height: size.height)
            }
            let animate = source != nil && destination != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            var revision = item
            let reference = try editors.hold(data: original, title: item.title, origin: destination,
                showImmediately: !animate,
                onCloseToShelf: { [weak self] updated, currentFrame in
                    guard let self else { throw CaptureError.invalidMedia }
                    if updated != original || revision.digest != item.digest {
                        try self.session.store.addEditedImage(updated, limit: self.session.limit) { historyID in
                            revision = try self.library.overwriteImage(id: item.id, expectedDigest: revision.digest,
                                data: updated, historyID: historyID)
                        }
                    }
                    try self.library.returnToShelf(item.id, origin: currentFrame)
                }, onDestroy: { [weak self] in
                    guard let self else { throw CaptureError.invalidMedia }
                    try self.library.remove(item.id)
                }, onClosed: { [weak library] in
                    library?.releaseHeldItem(item.id)
                })
            guard library.takeFromShelf(item.id) else { reference.close(); return }
            if animate, let source, let shelf {
                liftingCaptureIDs.insert(item.id)
                shelf.presentReference(reference, image: image, from: source) { [weak self] in
                    self?.liftingCaptureIDs.remove(item.id)
                }
            }
        }
    }
    func edit(_ item: CaptureItem) {
        shelf?.hide()
        editors.edit(library.url(for: item), movie: item.kind == .movie, onOverwrite: { [weak self] result in
            guard let self else { throw CaptureError.invalidMedia }
            let data = try Data(contentsOf: result)
            try self.session.store.addEditedImage(data, limit: self.session.limit) { historyID in
                try self.library.overwriteImage(id: item.id, expectedDigest: item.digest, data: data, historyID: historyID)
            }
        })
    }
    func open(_ item: CaptureItem) {
        NSWorkspace.shared.open(library.url(for: item))
    }
    func export(_ item: CaptureItem) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.title.contains(".") ? item.title : "\(item.title).\(library.url(for: item).pathExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: library.url(for: item).pathExtension) ?? .data]
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] result in
            guard let self, result == .OK, let destination = panel.url else { return }
            perform {
                let source = self.library.url(for: item)
                guard source.standardizedFileURL != destination.standardizedFileURL else { return }
                // NSSavePanel has already confirmed replacement. Atomic writing preserves the old file on failure.
                if item.kind == .image { try Data(contentsOf: source).write(to: destination, options: .atomic) }
                else {
                    let temporary = destination.deletingLastPathComponent().appendingPathComponent(".pastes-export-\(UUID())")
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try FileManager.default.copyItem(at: source, to: temporary)
                    if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary) }
                    else { try FileManager.default.moveItem(at: temporary, to: destination) }
                }
            }
        }
    }
    func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }
}
