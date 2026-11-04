import AppKit
import Combine
import SwiftUI

@MainActor
final class CaptureImageEditor: NSObject, ObservableObject, NSWindowDelegate {
    let document: ImageAnnotationDocument
    private(set) var window: NSWindow?
    private let onSaved: (URL) async throws -> Void
    private let onOverwrite: ((URL) async throws -> Void)?
    var overwriteHelp = C("更新图片架中的当前图片，保留固定状态；不修改外部源文件。", "Replace the current shelf image and keep its pinned state. External source files are unchanged.")
    var canOverwrite: Bool { onOverwrite != nil }
    @Published var saving = false
    @Published var errorMessage: String?
    private var saved = false

    init(url: URL, onSaved: @escaping (URL) async throws -> Void, onOverwrite: ((URL) async throws -> Void)? = nil) throws {
        document = try ImageAnnotationDocument(url: url)
        self.onSaved = onSaved
        self.onOverwrite = onOverwrite
    }
    func show() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = AppEnvironment.displayName + " · " + C("图片编辑", "Image editor")
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isOpaque = false; window.backgroundColor = .clear
        window.isReleasedWhenClosed = false; window.delegate = self
        let host = NSHostingView(rootView: CaptureImageEditorView(editor: self, document: document)
            .frame(minWidth: 800, minHeight: 500))
        host.sizingOptions = [.minSize]
        window.contentView = host
        window.contentMinSize = NSSize(width: 800, height: 500)
        self.window = window; window.center()
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    func save() { save(overwrite: false) }
    func overwrite() { save(overwrite: true) }
    private func save(overwrite: Bool) {
        guard !saving, !overwrite || onOverwrite != nil else { return }
        saving = true
        Task {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Pastes-Edit-\(UUID())", isDirectory: true)
            defer { saving = false; try? FileManager.default.removeItem(at: directory) }
            do {
                let data = try document.exportPNG()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let result = directory.appendingPathComponent("Edited.png")
                try data.write(to: result, options: .atomic)
                if overwrite, let onOverwrite { try await onOverwrite(result) }
                else { try await onSaved(result) }
                saved = true; window?.close()
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func cancel() { window?.performClose(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !saving else { return false }
        guard !saved, document.hasChanges else { return true }
        let alert = NSAlert()
        alert.messageText = C("放弃未保存的编辑？", "Discard unsaved edits?")
        alert.informativeText = C("原始图片不会改变。", "The original image will remain unchanged.")
        alert.addButton(withTitle: C("继续编辑", "Keep editing"))
        alert.addButton(withTitle: C("放弃编辑", "Discard"))
        alert.beginSheetModal(for: sender) { [weak self] result in
            if result == .alertSecondButtonReturn { self?.saved = true; sender.close() }
        }
        return false
    }
    func windowWillClose(_ notification: Notification) { window = nil }
    func close() { window?.close() }
}

struct CaptureImageEditorView: View {
    @ObservedObject var editor: CaptureImageEditor
    @ObservedObject var document: ImageAnnotationDocument
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Label(C("图片编辑", "Image editor"), systemImage: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 8)
                Spacer(minLength: 12)
                ForEach(AnnotationTool.allCases, id: \.self) { tool in
                    Button { document.tool = tool } label: {
                        Image(systemName: tool.symbol)
                            .font(.system(size: 15, weight: .medium)).frame(width: 18, height: 18)
                    }
                    .buttonStyle(PastesGlassButtonStyle(prominence: document.tool == tool ? .accent : .standard, compact: true))
                    .help(tool.title).accessibilityLabel(tool.title)
                }
                Divider().frame(height: 20).padding(.horizontal, 3)
                Button(action: document.undo) { Image(systemName: "arrow.uturn.backward").frame(width: 18, height: 18) }
                    .disabled(!document.canUndo).keyboardShortcut("z", modifiers: .command)
                    .help(C("撤销", "Undo")).accessibilityLabel(C("撤销", "Undo"))
                Button(action: document.redo) { Image(systemName: "arrow.uturn.forward").frame(width: 18, height: 18) }
                    .disabled(!document.canRedo).keyboardShortcut("z", modifiers: [.command, .shift])
                    .help(C("重做", "Redo")).accessibilityLabel(C("重做", "Redo"))
                Button(action: document.deleteSelected) { Image(systemName: "trash").frame(width: 18, height: 18) }
                    .buttonStyle(PastesGlassButtonStyle(prominence: .destructive, compact: true))
                    .disabled(document.selection == nil)
                    .help(C("删除选中的标注", "Delete selected annotation"))
                    .accessibilityLabel(C("删除选中的标注", "Delete selected annotation"))
            }
            .padding(10).pastesGlass(cornerRadius: 24)
            HStack(spacing: 12) {
                ColorPicker(C("颜色", "Color"), selection: Binding(get: { Color(nsColor: document.color) }, set: { document.setColor(NSColor($0)) }), supportsOpacity: false).fixedSize()
                Text(C("线宽", "Width")).font(.system(size: 12, weight: .medium))
                Slider(value: Binding(get: { document.lineWidth }, set: document.setLineWidth), in: 1...20, step: 1).frame(width: 100)
                Text("\(Int(document.lineWidth)) px").font(.system(size: 11, weight: .medium)).monospacedDigit().frame(width: 40)
                Spacer()
                Text(C("选择工具后，按住鼠标拖拽绘制；用“选择”移动或拖动角点缩放。", "Drag to draw. Use Select to move or resize with corner handles."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 11).pastesGlass(cornerRadius: 22)
            AnnotationCanvasHost(document: document)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.28), lineWidth: 0.7).allowsHitTesting(false) }
            HStack(spacing: 10) {
                Text("\(Int(document.pixelSize.width)) × \(Int(document.pixelSize.height)) px")
                    .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 7).pastesGlass(cornerRadius: 20)
                if AppEnvironment.isDevelopment { Text("DEV").font(.caption.bold()).foregroundStyle(.orange) }
                Spacer()
                if editor.saving { ProgressView().controlSize(.small) }
                Button(C("取消", "Cancel"), action: editor.cancel)
                Button(C("另存副本", "Save copy"), action: editor.save).keyboardShortcut("s", modifiers: [.command, .shift])
                if editor.canOverwrite {
                    Button(C("覆盖原图", "Overwrite original"), action: editor.overwrite)
                        .buttonStyle(PastesGlassButtonStyle(prominence: .accent, compact: true)).keyboardShortcut("s", modifiers: .command)
                        .help(editor.overwriteHelp)
                }
            }.padding(.horizontal, 4).padding(.bottom, 2)
        }
        .buttonStyle(PastesGlassButtonStyle(compact: true))
        .padding(16).padding(.top, 26)
        .background(PastesWindowBackground(cornerRadius: 28))
        .ignoresSafeArea()
        .disabled(editor.saving)
        .alert(C("保存失败", "Save failed"), isPresented: Binding(get: { editor.errorMessage != nil }, set: { if !$0 { editor.errorMessage = nil } })) {
            Button("OK") { editor.errorMessage = nil }
        } message: { Text(editor.errorMessage ?? "") }
    }
}
