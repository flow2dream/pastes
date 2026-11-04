import AppKit
import Combine
import ScreenCaptureKit
import UniformTypeIdentifiers

struct ScreenshotGeometry {
    /// AppKit selection coordinates, normalized and clipped to the starting display.
    static func selection(from start: CGPoint, to end: CGPoint, in screen: CGRect) -> CGRect? {
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(screen)
        guard !rect.isNull, rect.width >= 3, rect.height >= 3 else { return nil }
        return rect
    }
    /// CGImage cropping uses a top-left origin; display positions may be negative.
    static func pixels(for selection: CGRect, screen: CGRect, imageSize: CGSize) -> CGRect? {
        let clipped = selection.intersection(screen)
        guard !clipped.isNull, clipped.width >= 3, clipped.height >= 3,
              screen.width > 0, screen.height > 0, imageSize.width > 0, imageSize.height > 0 else { return nil }
        let sx = imageSize.width / screen.width, sy = imageSize.height / screen.height
        return CGRect(x: (clipped.minX - screen.minX) * sx,
                      y: (screen.maxY - clipped.maxY) * sy,
                      width: clipped.width * sx, height: clipped.height * sy)
            .integral.intersection(CGRect(origin: .zero, size: imageSize))
    }
    static func sourceRect(for pixels: CGRect, screen: CGRect, imageSize: CGSize) -> CGRect {
        let sx = screen.width / imageSize.width, sy = screen.height / imageSize.height
        return CGRect(x: screen.minX + pixels.minX * sx,
                      y: screen.maxY - pixels.maxY * sy, width: pixels.width * sx, height: pixels.height * sy)
    }
}

struct ScreenshotFrame {
    let screen: CGRect
    let image: CGImage
    func crop(_ selection: CGRect) throws -> (data: Data, origin: CGRect) {
        let size = CGSize(width: image.width, height: image.height)
        guard let pixels = ScreenshotGeometry.pixels(for: selection, screen: screen, imageSize: size),
              let cropped = image.cropping(to: pixels),
              let data = NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:]) else {
            throw NativeScreenshotError.emptySelection
        }
        return (data, ScreenshotGeometry.sourceRect(for: pixels, screen: screen, imageSize: size))
    }
}

enum NativeScreenshotError: LocalizedError {
    case permission, noDisplay, emptySelection
    var errorDescription: String? {
        switch self {
        case .permission: return C("请在系统设置的“隐私与安全性 → 屏幕与系统音频录制”中允许本应用录制屏幕，再重新截图。", "Allow this app in System Settings → Privacy & Security → Screen & System Audio Recording, then try again.")
        case .noDisplay: return C("当前屏幕不可用，请重新截图。", "The display is unavailable. Try taking another screenshot.")
        case .emptySelection: return C("截图区域太小，请重新框选。", "The selection is too small. Select a larger area.")
        }
    }
}

@MainActor
final class NativeScreenshot: ObservableObject {
    @Published private(set) var isActive = false
    private var windows: [NSPanel] = []
    private var task: Task<Void, Never>?
    private var displayObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var generation = UUID()
    private let capture: () async throws -> [ScreenshotFrame]
    private let onActive: (Bool) -> Void
    private let onCaptured: (Data, CGRect) throws -> Void
    private let onSaved: (Data, CGRect) throws -> Void
    private let onPinned: (Data, CGRect) throws -> Void
    private var savePanel: NSSavePanel?
    private var editingImage: (data: Data, origin: CGRect)?
    private let onError: (Error) -> Void

    init(capture: @escaping () async throws -> [ScreenshotFrame] = NativeScreenshot.captureDisplays,
         onActive: @escaping (Bool) -> Void,
         onCaptured: @escaping (Data, CGRect) throws -> Void,
         onError: @escaping (Error) -> Void,
         onPinned: @escaping (Data, CGRect) throws -> Void = { _, _ in },
         onSaved: @escaping (Data, CGRect) throws -> Void = { _, _ in }) {
        self.capture = capture; self.onActive = onActive
        self.onCaptured = onCaptured; self.onError = onError; self.onPinned = onPinned
        self.onSaved = onSaved
    }
    func beginEditing(data: Data, origin: CGRect) {
        guard !isActive else { return }
        editingImage = (data, origin)
        begin()
    }
    func begin() {
        guard !isActive else { return }
        generation = UUID()
        let current = generation
        isActive = true; onActive(true)
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Bringing up a save dialog can activate our app's Space. Keep that
                // explicit save transaction alive; ordinary selection switches cancel.
                guard let self, self.savePanel == nil else { return }
                self.cancel()
            }
        }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                // Allow the shelf and clicked menu to disappear before freezing the desktop.
                try await Task.sleep(for: .milliseconds(180))
                let frames: [ScreenshotFrame]
                if let edit = editingImage {
                    guard let image = NSImage(data: edit.data)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                          let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: edit.origin.midX, y: edit.origin.midY)) }) ?? NSScreen.main else { throw CaptureError.invalidMedia }
                    frames = [ScreenshotFrame(screen: screen.frame, image: image)]
                } else { frames = try await capture() }
                try Task.checkCancellation()
                guard current == generation else { return }
                guard !frames.isEmpty else { throw NativeScreenshotError.noDisplay }
                showSelection(frames)
            } catch {
                guard current == generation else { return }
                finish()
                if !(error is CancellationError) { onError(error) }
            }
        }
    }
    func cancel() {
        generation = UUID(); task?.cancel(); task = nil
        savePanel?.cancel(nil); savePanel = nil
        finish()
    }
    private func finish() {
        for window in windows { window.orderOut(nil); window.contentView = nil }
        windows.removeAll()
        editingImage = nil
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        displayObserver = nil; spaceObserver = nil
        if isActive { isActive = false; onActive(false) }
        NSCursor.arrow.set()
    }
    private func showSelection(_ frames: [ScreenshotFrame]) {
        for frame in frames {
            let panel = ScreenshotSelectionPanel(contentRect: frame.screen,
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            CaptureOverlayPolicy.configure(panel)
            panel.level = .screenSaver
            panel.isOpaque = editingImage == nil; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            let view = ScreenshotSelectionView(frame: CGRect(origin: .zero, size: frame.screen.size), capture: frame,
                onSelection: { [weak self, weak panel] rect in
                    guard let view = panel?.contentView as? ScreenshotSelectionView else { return }
                    self?.complete(view: view, selection: rect)
                },
                onCancel: { [weak self] in self?.cancel() },
                onSave: { [weak self, weak panel] rect in
                    guard let view = panel?.contentView as? ScreenshotSelectionView else { return }
                    self?.save(view: view, selection: rect)
                }, onPin: { [weak self, weak panel] rect in
                    guard let view = panel?.contentView as? ScreenshotSelectionView else { return }
                    self?.complete(view: view, selection: rect, pin: true)
                })
            panel.contentView = view
            if let edit = editingImage { view.prepareImageEditing(data: edit.data, origin: edit.origin) }
            windows.append(panel)
            panel.orderFrontRegardless()
            if editingImage != nil || frame.screen.contains(NSEvent.mouseLocation) {
                panel.makeKey(); view.focusEditor()
            }
        }
        (editingImage == nil ? NSCursor.crosshair : NSCursor.arrow).set()
    }
    private func complete(view: ScreenshotSelectionView, selection: CGRect, pin: Bool = false) {
        guard isActive else { return }
        do {
            let data = try view.exportPNG()
            let origin = try view.outputOrigin()
            // Import while selection is still onscreen; finish before the scheduled reveal.
            if pin { try onPinned(data, origin) }
            else { try onCaptured(data, origin) }
            finish()
        } catch { view.showError(error.localizedDescription) }
    }
    private func save(view: ScreenshotSelectionView, selection: CGRect) {
        guard isActive, savePanel == nil else { return }
        do {
            let data = try view.exportPNG()
            let origin = try view.outputOrigin()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "Screenshot.png"
            savePanel = panel
            let current = generation
            for window in windows { window.orderOut(nil) }
            NSApp.activate(ignoringOtherApps: true)
            panel.begin { [weak self, weak view] response in
                guard let self, let view, current == self.generation, self.isActive else { return }
                self.savePanel = nil
                if response == .OK, let url = panel.url {
                    do {
                        try self.savePNG(data, origin: origin, to: url)
                        self.finish()
                        return
                    } catch { view.showError(error.localizedDescription) }
                }
                for window in self.windows { window.orderFrontRegardless() }
                view.window?.makeKey(); view.window?.makeFirstResponder(view)
            }
        } catch { view.showError(error.localizedDescription) }
    }
    func savePNG(_ data: Data, origin: CGRect, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        // Editing a floating image may apply the saved changes to that image.
        // A newly captured screenshot has no save callback and only writes the file.
        try onSaved(data, origin)
    }
    static func captureDisplays() async throws -> [ScreenshotFrame] {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw NativeScreenshotError.permission
        }
        let screens = NSScreen.screens.map { screen in
            (id: (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
             frame: screen.frame, scale: screen.backingScaleFactor)
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var frames: [ScreenshotFrame] = []
        for screen in screens {
            try Task.checkCancellation()
            guard let display = content.displays.first(where: { $0.displayID == screen.id }) else { throw NativeScreenshotError.noDisplay }
            let configuration = SCStreamConfiguration()
            configuration.width = Int((screen.frame.width * screen.scale).rounded())
            configuration.height = Int((screen.frame.height * screen.scale).rounded())
            configuration.showsCursor = false
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            frames.append(ScreenshotFrame(screen: screen.frame, image: image))
        }
        return frames
    }
}

final class ScreenshotSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class ScreenshotSelectionView: NSView {
    let capture: ScreenshotFrame
    private let screenshot: NSImage
    private let onSelection: (CGRect) -> Void
    private let onCancel: () -> Void
    private let onSave: (CGRect) -> Void
    private let onPin: (CGRect) -> Void
    private var document: ImageAnnotationDocument?
    private var editingData: Data?
    private var reselectButton: NSButton?
    private var copyButton: ScreenshotToolButton?
    private var pinButton: ScreenshotToolButton?
    private var canvas: ImageAnnotationCanvas?
    private let toolbar = ScreenshotToolbar()
    private var toolButtons: [NSButton] = []
    private var colorButtons: [ScreenshotToolButton] = []
    private var widthButtons: [ScreenshotToolButton] = []
    private var undoButton: NSButton?
    private var redoButton: NSButton?
    private var deleteButton: NSButton?
    private var toolbarSubscription: AnyCancellable?
    private let strokeSlider = ScreenshotStrokeSlider(value: 4, minValue: 1, maxValue: 20, target: nil, action: nil)
    private static let colors: [NSColor] = [.systemRed, .systemOrange, .systemGreen, .systemBlue, .black, .white]
    private var errorText: String?
    private var dragSelection: CGRect?
    private var resizeIndex: Int?
    private var start: CGPoint?
    private(set) var selection: CGRect?
    private var tracking: NSTrackingArea?
    init(frame: CGRect, capture: ScreenshotFrame, onSelection: @escaping (CGRect) -> Void, onCancel: @escaping () -> Void, onSave: @escaping (CGRect) -> Void = { _ in }, onPin: @escaping (CGRect) -> Void = { _ in }) {
        self.capture = capture
        screenshot = NSImage(cgImage: capture.image, size: capture.screen.size)
        self.onSelection = onSelection; self.onCancel = onCancel; self.onSave = onSave; self.onPin = onPin
        super.init(frame: frame)
        buildToolbar()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: selection == nil ? .crosshair : .arrow) }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        tracking = area; addTrackingArea(area)
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) {
        window?.makeKey(); window?.makeFirstResponder(self); (selection == nil ? NSCursor.crosshair : .arrow).set()
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey(); window?.makeFirstResponder(self)
        beginSelection(at: NSEvent.mouseLocation)
    }
    override func mouseDragged(with event: NSEvent) {
        updateSelection(to: NSEvent.mouseLocation)
    }
    override func mouseUp(with event: NSEvent) {
        finishSelection(at: NSEvent.mouseLocation)
    }
    func beginSelection(at point: CGPoint) {
        guard editingData == nil else { return }
        if document?.hasChanges == true { return }
        start = point; errorText = nil
        if let selection {
            resizeIndex = Self.handles(selection).firstIndex { hypot($0.x - point.x, $0.y - point.y) <= 9 }
            dragSelection = resizeIndex != nil || selection.contains(point) ? selection : nil
        } else { dragSelection = nil; resizeIndex = nil }
        if dragSelection == nil { selection = nil }
        canvas?.removeFromSuperview(); canvas = nil; document = nil
        toolbar.isHidden = true; needsDisplay = true
    }
    func updateSelection(to point: CGPoint) {
        guard let start else { return }
        if let rect = dragSelection {
            if let index = resizeIndex {
                selection = Self.resized(rect, handle: index, to: point, in: capture.screen)
            } else {
                let x = min(max(rect.minX + point.x - start.x, capture.screen.minX), capture.screen.maxX - rect.width)
                let y = min(max(rect.minY + point.y - start.y, capture.screen.minY), capture.screen.maxY - rect.height)
                selection = CGRect(x: x, y: y, width: rect.width, height: rect.height)
            }
        } else { selection = ScreenshotGeometry.selection(from: start, to: point, in: capture.screen) }
        needsDisplay = true
    }
    func finishSelection(at point: CGPoint) {
        guard start != nil else { return }
        updateSelection(to: point)
        start = nil; dragSelection = nil; resizeIndex = nil
        prepareSelection()
    }
    func confirmCopy() { if let selection, document != nil { onSelection(selection) } }
    @objc func confirmPin() { if let selection, document != nil { onPin(selection) } }
    func confirmSave() { if let selection, document != nil { onSave(selection) } }
    func focusEditor() { window?.makeFirstResponder(canvas ?? self) }
    func prepareImageEditing(data: Data, origin: CGRect) {
        editingData = data; selection = origin
        prepareSelection()
        reselectButton?.isEnabled = false
        copyButton?.setHint(C("复制并应用修改（Enter / ⌘C）", "Copy and apply edits (Enter / ⌘C)"))
        pinButton?.setHint(C("应用修改并保持固定", "Apply edits and keep pinned"))
        if let button = toolButtons.first { chooseTool(button) }
    }
    func outputOrigin() throws -> CGRect {
        guard let selection else { throw NativeScreenshotError.emptySelection }
        return editingData == nil ? try capture.crop(selection).origin : selection
    }
    func exportPNG() throws -> Data {
        guard let document else { throw NativeScreenshotError.emptySelection }
        return try document.exportPNG()
    }
    func showError(_ text: String) { errorText = text; needsDisplay = true }
    private func prepareSelection() {
        guard let selection else { toolbar.isHidden = true; return }
        do {
            document = try ImageAnnotationDocument(data: editingData ?? capture.crop(selection).data)
            document?.tool = .select
            toolbarSubscription = document?.objectWillChange.sink { [weak self] in
                DispatchQueue.main.async { self?.refreshToolbar() }
            }
            refreshToolbar()
            toolbar.isHidden = false
            placeToolbar()
            window?.invalidateCursorRects(for: self)
        } catch { showError(error.localizedDescription) }
        needsDisplay = true
    }
    static func handles(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY),
         CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)]
    }
    static func resized(_ rect: CGRect, handle: Int, to point: CGPoint, in screen: CGRect) -> CGRect {
        var x1 = rect.minX, x2 = rect.maxX, y1 = rect.minY, y2 = rect.maxY
        if [0, 6, 7].contains(handle) { x1 = min(x2 - 3, max(screen.minX, point.x)) }
        if [2, 3, 4].contains(handle) { x2 = max(x1 + 3, min(screen.maxX, point.x)) }
        if [0, 1, 2].contains(handle) { y1 = min(y2 - 3, max(screen.minY, point.y)) }
        if [4, 5, 6].contains(handle) { y2 = max(y1 + 3, min(screen.maxY, point.y)) }
        return CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }
    private func placeToolbar() {
        guard let selection else { return }
        let local = selection.offsetBy(dx: -capture.screen.minX, dy: -capture.screen.minY)
        let width = min(490, bounds.width - 16), height: CGFloat = 80
        let y = local.minY >= height + 12 ? local.minY - height - 10 : min(bounds.height - height - 8, local.maxY + 10)
        toolbar.frame = CGRect(x: min(max(8, local.maxX - width), bounds.width - width - 8), y: max(8, y), width: width, height: height)
    }
    private func buildToolbar() {
        toolbar.isHidden = true; addSubview(toolbar)
        let tools = NSStackView(); tools.orientation = .horizontal; tools.spacing = 2
        func separator(_ row: NSStackView) {
            let line = NSBox(); line.boxType = .separator
            line.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([line.widthAnchor.constraint(equalToConstant: 1), line.heightAnchor.constraint(equalToConstant: 22)])
            row.addArrangedSubview(line); row.setCustomSpacing(6, after: line)
        }
        for (index, tool) in AnnotationTool.allCases.enumerated() {
            let button = ScreenshotToolButton(symbol: tool.symbol, label: tool.title, target: self, action: #selector(chooseTool(_:)))
            button.tag = index; tools.addArrangedSubview(button); toolButtons.append(button)
        }
        separator(tools)
        for (symbol, title, selector) in [
            ("arrow.uturn.backward", C("撤销（⌘Z）", "Undo (⌘Z)"), #selector(undoAnnotation)),
            ("arrow.uturn.forward", C("重做（⇧⌘Z）", "Redo (⇧⌘Z)"), #selector(redoAnnotation)),
            ("eraser", C("删除选中的标注", "Delete selected annotation"), #selector(deleteAnnotation)),
            ("crop", C("重新框选", "Reselect"), #selector(reselect))] {
            let button = ScreenshotToolButton(symbol: symbol, label: title, target: self, action: selector)
            tools.addArrangedSubview(button)
            if selector == #selector(undoAnnotation) { undoButton = button }
            if selector == #selector(redoAnnotation) { redoButton = button }
            if selector == #selector(deleteAnnotation) { deleteButton = button }
            if selector == #selector(reselect) { reselectButton = button }
        }
        separator(tools)
        for (symbol, title, selector) in [
            ("pin.fill", C("固定到屏幕（保持置顶）", "Pin to screen (always on top)"), #selector(confirmPin)),
            ("square.and.arrow.down", C("另存为（⌘S）", "Save as (⌘S)"), #selector(saveCapture)),
            ("checkmark", C("复制并挂上（Enter / ⌘C）", "Copy & hang (Enter / ⌘C)"), #selector(copyCapture)),
            ("xmark", C("取消（Esc）", "Cancel (Esc)"), #selector(cancelCapture))] {
            let button = ScreenshotToolButton(symbol: symbol, label: title, target: self, action: selector)
            tools.addArrangedSubview(button)
            if selector == #selector(copyCapture) { copyButton = button }
            if selector == #selector(confirmPin) { pinButton = button }
        }
        let options = NSStackView(); options.orientation = .horizontal; options.spacing = 2; options.alignment = .centerY
        for (index, width) in [CGFloat(2), 4, 8].enumerated() {
            let button = ScreenshotToolButton(symbol: "circle.fill", label: C("线宽 \(Int(width))", "Stroke width \(Int(width))"), target: self, action: #selector(chooseWidth(_:)))
            button.tag = Int(width); button.dotSize = [CGFloat(3), 6, 10][index]
            options.addArrangedSubview(button); widthButtons.append(button)
        }
        separator(options)
        for (index, color) in Self.colors.enumerated() {
            let names = [C("红色", "Red"), C("橙色", "Orange"), C("绿色", "Green"), C("蓝色", "Blue"), C("黑色", "Black"), C("白色", "White")]
            let button = ScreenshotToolButton(symbol: "circle.fill", label: names[index], target: self, action: #selector(chooseColor(_:)))
            button.tag = index; button.swatch = color
            options.addArrangedSubview(button); colorButtons.append(button)
        }
        separator(options)
        strokeSlider.target = self; strokeSlider.action = #selector(changeWidth(_:))
        strokeSlider.isContinuous = true; strokeSlider.hintText = C("线宽 1–20 px", "Stroke width 1–20 px")
        strokeSlider.setAccessibilityLabel(C("线宽", "Stroke width"))
        strokeSlider.widthAnchor.constraint(equalToConstant: 96).isActive = true
        options.addArrangedSubview(strokeSlider)
        toolbar.install(tools: tools, options: options)
    }
    private func refreshToolbar() {
        guard let document else { return }
        for button in toolButtons {
            button.state = AnnotationTool.allCases[button.tag] == document.tool ? .on : .off
        }
        for button in colorButtons { button.state = Self.colors[button.tag].isEqual(document.color) ? .on : .off }
        for button in widthButtons { button.state = CGFloat(button.tag) == document.lineWidth ? .on : .off }
        strokeSlider.doubleValue = Double(document.lineWidth)
        strokeSlider.hintText = C("线宽：\(Int(document.lineWidth)) px", "Stroke width: \(Int(document.lineWidth)) px")
        undoButton?.isEnabled = document.canUndo; redoButton?.isEnabled = document.canRedo
        deleteButton?.isEnabled = document.selection != nil
    }
    @objc private func chooseWidth(_ sender: NSButton) { document?.setLineWidth(CGFloat(sender.tag)); refreshToolbar() }
    @objc private func changeWidth(_ sender: NSSlider) { document?.setLineWidth(CGFloat(sender.doubleValue.rounded())); refreshToolbar() }
    @objc private func chooseTool(_ sender: NSButton) {
        guard let document, let selection else { return }
        document.tool = AnnotationTool.allCases[sender.tag]
        for button in toolButtons { button.state = button === sender ? .on : .off }
        if canvas == nil {
            let view = ImageAnnotationCanvas(document: document)
            view.edgeToEdge = true
            view.onEscape = { [weak self] in self?.onCancel() }
            view.frame = selection.offsetBy(dx: -capture.screen.minX, dy: -capture.screen.minY)
            addSubview(view, positioned: .below, relativeTo: toolbar); canvas = view
        }
        window?.makeFirstResponder(canvas)
        needsDisplay = true
    }
    @objc private func chooseColor(_ sender: NSButton) { document?.setColor(Self.colors[sender.tag]); refreshToolbar() }
    @objc private func undoAnnotation() { document?.undo() }
    @objc private func redoAnnotation() { document?.redo() }
    @objc private func deleteAnnotation() { document?.deleteSelected() }
    @objc private func cancelCapture() { onCancel() }
    @objc private func copyCapture() { confirmCopy() }
    @objc private func saveCapture() { confirmSave() }
    @objc private func reselect() {
        guard editingData == nil else { return }
        canvas?.removeFromSuperview(); canvas = nil; document = nil; selection = nil
        toolbar.isHidden = true; errorText = nil; needsDisplay = true
        window?.makeFirstResponder(self)
    }
    override func rightMouseDown(with event: NSEvent) { onCancel() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel() }
        else if event.keyCode == 49 && editingData == nil { selection = capture.screen; prepareSelection() }
        else if event.keyCode == 36 || (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "c") { confirmCopy() }
        else if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "s" { confirmSave() }
        else { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if document != nil, event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers == "c" { confirmCopy(); return true }
            if event.charactersIgnoringModifiers == "s" { confirmSave(); return true }
        }
        return super.performKeyEquivalent(with: event)
    }
    override func cancelOperation(_ sender: Any?) { onCancel() }
    override func draw(_ dirtyRect: NSRect) {
        if editingData != nil, let selection {
            screenshot.draw(in: selection.offsetBy(dx: -capture.screen.minX, dy: -capture.screen.minY))
        } else { screenshot.draw(in: bounds) }
        NSColor.black.withAlphaComponent(0.38).setFill()
        if let selection {
            let local = selection.offsetBy(dx: -capture.screen.minX, dy: -capture.screen.minY)
            for rect in [CGRect(x: 0, y: 0, width: bounds.width, height: local.minY),
                         CGRect(x: 0, y: local.maxY, width: bounds.width, height: max(0, bounds.height - local.maxY)),
                         CGRect(x: 0, y: local.minY, width: local.minX, height: local.height),
                         CGRect(x: local.maxX, y: local.minY, width: max(0, bounds.width - local.maxX), height: local.height)] { rect.fill() }
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: local.insetBy(dx: 0.5, dy: 0.5)); border.lineWidth = 1; border.stroke()
            if document != nil && canvas == nil {
                for point in Self.handles(local) {
                    NSColor.white.setFill()
                    CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6).fill()
                }
            }
            let pixels = editingData != nil ? CGRect(origin: .zero, size: document?.pixelSize ?? .zero) : ScreenshotGeometry.pixels(for: selection, screen: capture.screen, imageSize: CGSize(width: capture.image.width, height: capture.image.height)) ?? .zero
            drawLabel("\(Int(pixels.width)) × \(Int(pixels.height))", at: CGPoint(x: min(local.minX, max(0, bounds.width - 140)), y: min(bounds.height - 34, local.maxY + 8)))
        } else { bounds.fill() }
        drawLabel(errorText ?? (editingData != nil ? C("编辑固定图片 · 图钉确认修改 · Enter 复制 · Esc 取消", "Edit pinned image · Pin applies changes · Enter copies · Esc cancels") : document == nil ? C("拖动框选 · 空格选择当前屏幕 · Esc 取消", "Drag to select · Space selects this screen · Esc cancels") : C("拖动调整选区 · 标注后选择复制或另存 · Enter 复制 · Esc 取消", "Adjust the selection · Annotate, then copy or save · Enter copies · Esc cancels")), at: CGPoint(x: 24, y: bounds.height - 52))
    }
    private func drawLabel(_ text: String, at point: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        let capsule = NSBezierPath(roundedRect: CGRect(x: point.x, y: point.y, width: size.width + 20, height: size.height + 12), xRadius: 14, yRadius: 14)
        NSColor(calibratedWhite: 0.14, alpha: 0.84).setFill(); capsule.fill()
        NSColor.white.withAlphaComponent(0.38).setStroke(); capsule.lineWidth = 0.7; capsule.stroke()
        (text as NSString).draw(at: CGPoint(x: point.x + 10, y: point.y + 6), withAttributes: attributes)
    }
}


private final class ScreenshotToolbar: NSView {
    private let toolsGlass = ScreenshotGlassSurface(cornerRadius: 20)
    private let optionsGlass = ScreenshotGlassSurface(cornerRadius: 18)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(toolsGlass); addSubview(optionsGlass)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func install(tools: NSView, options: NSView) {
        toolsGlass.content.addSubview(tools)
        optionsGlass.content.addSubview(options)
        tools.translatesAutoresizingMaskIntoConstraints = false
        options.translatesAutoresizingMaskIntoConstraints = false
        // Local constraints survive moving each content view to its opaque
        // accessibility fallback, while retaining the original button positions.
        NSLayoutConstraint.activate([
            tools.leadingAnchor.constraint(equalTo: toolsGlass.content.leadingAnchor, constant: 6.5),
            tools.topAnchor.constraint(equalTo: toolsGlass.content.topAnchor, constant: 4.5),
            options.leadingAnchor.constraint(equalTo: optionsGlass.content.leadingAnchor, constant: 6.5),
            options.centerYAnchor.constraint(equalTo: optionsGlass.content.bottomAnchor, constant: -17.5)
        ])
    }

    override func layout() {
        super.layout()
        toolsGlass.frame = CGRect(x: 0.5, y: bounds.height - 40.5, width: max(0, bounds.width - 1), height: 40)
        optionsGlass.frame = CGRect(x: 0.5, y: 0.5, width: max(0, min(420, bounds.width) - 1), height: 36)
    }
}

/// Keep controls in the native effect's content view, with an opaque alternative
/// for Reduce Transparency. The photo and selection never pass through this view.
private final class ScreenshotGlassSurface: NSView {
    let content = NSView()
    private let glass = NSGlassEffectView()
    private let rim = CAShapeLayer()
    private let innerRim = CAShapeLayer()
    private let radius: CGFloat

    init(cornerRadius: CGFloat) {
        radius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.cornerRadius = cornerRadius
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        glass.style = .regular
        glass.cornerRadius = cornerRadius
        content.wantsLayer = true
        content.layer?.cornerRadius = cornerRadius
        content.layer?.masksToBounds = true
        addSubview(glass)
        rim.fillColor = nil
        rim.lineWidth = 0.85
        layer?.addSublayer(rim)
        innerRim.fillColor = nil
        innerRim.lineWidth = 0.5
        layer?.addSublayer(innerRim)
        updateMaterial()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        glass.frame = bounds
        content.frame = bounds
        guard bounds.width > 0.8, bounds.height > 0.8 else {
            rim.path = nil; innerRim.path = nil; layer?.shadowPath = nil
            return
        }
        let local = CGRect(origin: .zero, size: bounds.size)
        let path = CGPath(roundedRect: local.insetBy(dx: 0.4, dy: 0.4),
            cornerWidth: radius, cornerHeight: radius, transform: nil)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        rim.frame = bounds; innerRim.frame = bounds
        rim.contentsScale = scale; innerRim.contentsScale = scale
        rim.zPosition = 100; innerRim.zPosition = 101
        rim.path = path
        innerRim.path = CGPath(roundedRect: local.insetBy(dx: 1.2, dy: 1.2),
            cornerWidth: max(0, radius - 0.8), cornerHeight: max(0, radius - 0.8), transform: nil)
        layer?.shadowPath = path
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateMaterial()
    }

    @objc private func displayOptionsChanged() { updateMaterial() }

    private func updateMaterial() {
        let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        CATransaction.begin(); CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = opaque ? NSColor.windowBackgroundColor.cgColor : NSColor.clear.cgColor
            content.layer?.backgroundColor = opaque ? NSColor.windowBackgroundColor.cgColor
                : NSColor(calibratedWhite: dark ? 0.06 : 0.60, alpha: dark ? 0.32 : 0.12).cgColor
        }
        rim.strokeColor = NSColor.white.withAlphaComponent(dark ? 0.42 : 0.82).cgColor
        innerRim.strokeColor = NSColor.black.withAlphaComponent(dark ? 0.16 : 0.10).cgColor
        CATransaction.commit()
        glass.tintColor = NSColor(calibratedWhite: dark ? 0.06 : 0.60, alpha: dark ? 0.28 : 0.12)
        glass.isHidden = opaque
        if opaque {
            if glass.contentView != nil {
                glass.contentView = nil
                content.removeFromSuperview()
            }
            if content.superview !== self { addSubview(content) }
        } else if glass.contentView !== content {
            content.removeFromSuperview()
            glass.contentView = content
        }
        needsLayout = true
    }
}

private final class ScreenshotToolButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    var swatch: NSColor?
    var dotSize: CGFloat?
    private var hovered = false
    private let hint = ScreenshotHoverHint()
    private var tracking: NSTrackingArea?
    init(symbol: String, label: String, target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        self.target = target; self.action = action
        title = ""; hint.text = label; setAccessibilityLabel(label)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(.init(pointSize: 17, weight: .medium))
        imagePosition = .imageOnly; isBordered = false
        setButtonType(.momentaryChange)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 30), heightAnchor.constraint(equalToConstant: 30)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setHint(_ text: String) { hint.text = text; setAccessibilityLabel(text) }
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        tracking = area; addTrackingArea(area); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true; hint.begin(over: self) }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true; hint.hide() }
    override func mouseDown(with event: NSEvent) { hint.hide(); super.mouseDown(with: event) }
    override func viewWillMove(toWindow newWindow: NSWindow?) { hint.hide(); super.viewWillMove(toWindow: newWindow) }
    override func draw(_ dirtyRect: NSRect) {
        let selected = state == .on
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if selected || hovered && isEnabled {
            let shape = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            if selected {
                NSGradient(starting: NSColor.white.withAlphaComponent(0.98),
                    ending: NSColor(calibratedWhite: 0.93, alpha: 0.90))?.draw(in: shape, angle: -90)
                NSColor.white.withAlphaComponent(0.92).setStroke()
            } else {
                NSColor.white.withAlphaComponent(dark ? 0.14 : 0.34).setFill(); shape.fill()
                NSColor.white.withAlphaComponent(dark ? 0.30 : 0.66).setStroke()
            }
            shape.lineWidth = 0.7; shape.stroke()
        }
        if let swatch {
            let rect = CGRect(x: bounds.midX - 7, y: bounds.midY - 7, width: 14, height: 14)
            swatch.setFill(); NSBezierPath(ovalIn: rect).fill()
            NSColor.labelColor.withAlphaComponent(0.25).setStroke()
            let outline = NSBezierPath(ovalIn: rect); outline.lineWidth = 0.7; outline.stroke()
        } else if let dotSize {
            (selected ? NSColor.systemBlue : NSColor.labelColor).setFill()
            NSBezierPath(ovalIn: CGRect(x: bounds.midX - dotSize / 2, y: bounds.midY - dotSize / 2, width: dotSize, height: dotSize)).fill()
        } else {
            let tint: NSColor = selected ? .systemBlue : .labelColor
            if contentTintColor != tint { contentTintColor = tint }
            super.draw(dirtyRect)
        }
    }
}

/// Own timer avoids the system tooltip delay, which varies by user preferences.
@MainActor
private final class ScreenshotHoverHint {
    var text = ""
    private var task: Task<Void, Never>?
    private var panel: NSPanel?
    func begin(over view: NSView) {
        hide()
        task = Task { [weak self, weak view] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, let view, let window = view.window, window.isVisible else { return }
            let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
            let label = NSTextField(labelWithString: self.text)
            label.font = .systemFont(ofSize: 12); label.textColor = .labelColor
            label.sizeToFit()
            let size = CGSize(width: label.frame.width + 20, height: 30)
            let screen = window.screen?.visibleFrame ?? window.frame
            let x = max(screen.minX + 4, min(anchor.midX - size.width / 2, screen.maxX - size.width - 4))
            let y = anchor.minY - 36 >= screen.minY ? anchor.minY - 36 : anchor.maxY + 6
            let panel = NSPanel(contentRect: CGRect(x: x, y: y, width: size.width, height: size.height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
            panel.ignoresMouseEvents = true; panel.hasShadow = true
            panel.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
            let content = ScreenshotGlassSurface(cornerRadius: 15)
            content.frame = CGRect(origin: .zero, size: size)
            label.frame.origin = CGPoint(x: 10, y: (30 - label.frame.height) / 2)
            content.content.addSubview(label); panel.contentView = content
            window.addChildWindow(panel, ordered: .above)
            panel.orderFrontRegardless(); self.panel = panel
        }
    }
    func hide() {
        task?.cancel(); task = nil
        if let panel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
        panel = nil
    }
}

private final class ScreenshotStrokeSlider: NSSlider {
    private let hint = ScreenshotHoverHint()
    private var tracking: NSTrackingArea?
    var hintText: String { get { hint.text } set { hint.text = newValue } }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        tracking = area; addTrackingArea(area); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hint.begin(over: self) }
    override func mouseExited(with event: NSEvent) { hint.hide() }
    override func mouseDown(with event: NSEvent) { hint.hide(); super.mouseDown(with: event) }
    override func viewWillMove(toWindow newWindow: NSWindow?) { hint.hide(); super.viewWillMove(toWindow: newWindow) }
}
