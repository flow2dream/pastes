import SwiftUI
import Carbon.HIToolbox

struct CaptureSettingsView: View {
    @ObservedObject var controller: CaptureController
    @ViewState private var confirmPurge = false
    @AppStorage("appLanguage") private var language: AppLanguage = .zh

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            screenshotGroup
            shelfGroup
            if controller.enabled { collectionGroup }
            if let message = controller.errorMessage {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button { controller.errorMessage = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(PastesGlassButtonStyle(compact: true))
                    .accessibilityLabel(C("关闭提示", "Dismiss message"))
                }
                .padding(14)
                .pastesGlass(cornerRadius: 20, tint: .red.opacity(0.07))
            }
            Text(C("文件保存在：", "Files stored in: ") + controller.library.directory.path)
                .font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
                .padding(.horizontal, 6)
        }
        .toggleStyle(.switch)
        .buttonStyle(PastesGlassButtonStyle(compact: true))
        .tint(.blue)
        .alert(C("清理已移除的媒体？", "Purge removed media?"), isPresented: $confirmPurge) {
            Button(C("取消", "Cancel"), role: .cancel) {}
            Button(C("永久清理", "Purge"), role: .destructive) { controller.perform { try controller.library.purgeHidden() } }
        } message: {
            Text(C("只清理本应用媒体库中已移除的副本，之后不能撤销移除。不会删除原始截图或剪贴板历史。", "Only removed copies in this app's library are deleted. Removal can no longer be undone. Original captures and clipboard history are preserved."))
        }
    }

    private var screenshotGroup: some View {
        captureGroup(C("截图与录屏", "Screenshots & recordings"), symbol: "viewfinder", tint: .purple) {
            HStack(spacing: 12) {
                Button(action: controller.takeScreenshot) {
                    Label(C("框选截图", "Take screenshot"), systemImage: "viewfinder")
                }
                .buttonStyle(PastesGlassButtonStyle(prominence: .accent, compact: true))
                .disabled(controller.screenshotActive)
                Spacer(minLength: 0)
                CaptureShortcutSettings(manager: controller.screenshotShortcut)
            }
            note(C("框选后可调整、标注，再选择复制、另存或固定到屏幕；空格选择当前屏幕，Esc 取消。首次使用需允许屏幕录制。", "Select a region, adjust or annotate it, then copy, save or pin it to the screen. Space selects this screen; Esc cancels. Screen recording permission is required on first use."))
            note(C("另存仅保存文件。固定截图暂不入架，右键关闭时挂到图片架，销毁直接丢弃。", "Save only writes the file. Pinned screenshots stay off the shelf until you close them from the context menu; Destroy discards them."))
        }
    }

    private var shelfGroup: some View {
        captureGroup(C("图片架", "Capture shelf"), symbol: "photo.stack.fill", tint: .blue) {
            toggleRow(C("启用顶部截图架", "Enable capture shelf"), binding: Binding(get: { controller.enabled }, set: controller.setEnabled))
            if controller.enabled {
                note(C("使用下方可自定义的快捷键显示或收起图片架；移开鼠标后自动收起，鼠标移到屏幕顶部不会展开。新增图片时仍会显示挂入动画。", "Use the customizable shortcut below to show or hide the shelf. It hides after the pointer moves away; hovering at the top edge does not open it. New images still show their arrival animation."))
                HStack(spacing: 12) {
                    Text(C("显示／收起图片架", "Show / hide shelf"))
                    Spacer(minLength: 0)
                    if let shortcut = controller.shelf?.shortcut { CaptureShortcutSettings(manager: shortcut) }
                }
                .padding(.vertical, 2)
                HStack(spacing: 8) {
                    Button { controller.shelf?.show() } label: {
                        Label(C("显示截图架", "Show shelf"), systemImage: "photo.stack")
                    }
                    Button(action: controller.chooseFiles) {
                        Label(C("导入文件…", "Import files…"), systemImage: "plus")
                    }
                    Spacer(minLength: 0)
                }
                sectionDivider
                toggleRow(C("在剪贴板列表中隐藏图片", "Hide images in clipboard history"), binding: Binding(get: { controller.hideImagesInHistory }, set: controller.setHideImagesInHistory))
                note(C("仅在图片架开启时隐藏，关闭后恢复显示；不会删除剪贴板记录。", "Images are hidden only while the shelf is enabled. Clipboard records are preserved."))
                sectionDivider
                CaptureRetentionSettingsView(controller: controller)
                note(C("图片与录屏共用上限；指定数量时固定项目不计入。超出后移除最旧的未固定项目；文件可通过“清理已移除文件”释放空间。", "The limit covers images and recordings; in Set count mode, pins are exempt. The oldest unpinned items leave the shelf; use Purge removed files to free disk space."))
            }
        }
    }

    private var collectionGroup: some View {
        captureGroup(C("采集与存储", "Collection & storage"), symbol: "tray.and.arrow.down.fill", tint: .orange) {
            toggleRow(C("收集复制的图片", "Collect copied images"), binding: Binding(get: { controller.copiedImages }, set: controller.setCopiedImages))
            sectionDivider
            toggleRow(C("监听系统截图目录", "Watch system screenshot folder"), binding: Binding(get: { controller.watchScreenshots }, set: controller.setWatching))
            sectionDivider
            HStack {
                Button { confirmPurge = true } label: {
                    Label(C("清理已移除文件…", "Purge removed files…"), systemImage: "trash")
                }
                .buttonStyle(PastesGlassButtonStyle(prominence: .destructive, compact: true))
                Spacer(minLength: 0)
            }
        }
    }

    private func captureGroup<Content: View>(_ title: String, symbol: String, tint: Color,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                PastesGlassIcon(symbol: symbol, tint: tint, size: 32)
                Text(title).font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer(minLength: 0)
            }
            .padding(.bottom, 2)
            content()
        }
        .padding(18)
        .pastesGlass(cornerRadius: 24)
        .shadow(color: .black.opacity(0.045), radius: 12, y: 5)
    }

    private var sectionDivider: some View { Divider().opacity(0.28) }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineSpacing(2)
    }

    private func toggleRow(_ title: String, binding: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Text(title).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Toggle(title, isOn: binding).labelsHidden()
        }
        .padding(.vertical, 2)
    }
}

private struct CaptureShortcutSettings: View {
    @ObservedObject var manager: HotkeyManager
    @ViewState private var recording = false
    @ViewState private var key: Int?
    @ViewState private var modifiers: Int?
    @ViewState private var error: String?
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button(recording ? C("按下快捷键…", "Press shortcut…") : manager.displayString) {
                key = nil; modifiers = nil; error = nil; recording.toggle()
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .buttonStyle(PastesGlassButtonStyle(prominence: recording ? .accent : .standard, compact: true))
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            if recording { Text(C("功能键或组合键 · Esc 取消", "Function key or modifiers · Esc cancels")).font(.caption).foregroundStyle(.secondary) }
        }
        .background(KeyEventHandler(isRecording: $recording, keyCode: $key, modifiers: $modifiers,
            onRecorded: {
                if let key, let modifiers, !manager.update(keyCode: key, modifiers: modifiers) {
                    error = manager.registrationError
                }
                recording = false
            }, onCancel: { recording = false }).frame(width: 1, height: 1))
        .onDisappear { recording = false }
    }
}


/// Keep the input as a draft: typing “35” must not first apply a destructive limit of 3.
private struct CaptureRetentionSettingsView: View {
    @ObservedObject var controller: CaptureController
    @ViewState private var draft = ""
    @ViewState private var invalid = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(C("图片架最多保留", "Shelf retention limit"))
                Spacer()
                Picker(C("图片架最多保留", "Shelf retention limit"), selection: Binding(
                    get: { controller.adaptiveRetention },
                    set: { adaptive in
                        invalid = false
                        if adaptive { controller.setAdaptiveRetention() }
                        else {
                            controller.selectCustomLimit()
                            draft = String(controller.maximumItems)
                        }
                    })) {
                    Text(C("自适应", "Fit screen")).tag(true)
                    Text(C("指定数量", "Set count")).tag(false)
                }.pickerStyle(.menu).labelsHidden().frame(width: 120)
            }
            if controller.adaptiveRetention {
                Text(C("根据图片架所在屏幕宽度铺满一屏，当前可容纳 \(controller.adaptiveCapacity) 项。固定项目占用位置；固定数量超过一屏时仍保留，可滚动查看。", "Fill one screen based on its width; currently \(controller.adaptiveCapacity) items fit. Pins occupy slots; excess pins are preserved and remain scrollable."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                HStack {
                    TextField(C("输入保留数量", "Number to retain"), text: $draft)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .frame(width: 100)
                        .pastesGlass(cornerRadius: 11)
                        .onSubmit(apply)
                        .accessibilityLabel(C("指定保留数量", "Retention count"))
                    Text(C("项", "items"))
                    Button(C("应用", "Apply"), action: apply)
                        .buttonStyle(PastesGlassButtonStyle(prominence: .accent, compact: true))
                    Spacer()
                    Text(controller.maximumItems > 0 ? C("当前：\(controller.maximumItems) 项", "Current: \(controller.maximumItems) items") : C("当前未设上限", "Currently unlimited"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if invalid {
                    Text(C("请输入大于 0 的整数。", "Enter a whole number greater than 0."))
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
        .onAppear { draft = controller.maximumItems > 0 ? String(controller.maximumItems) : "" }
    }
    private func apply() {
        guard let count = CaptureRetentionInput.parse(draft) else { invalid = true; return }
        invalid = false
        controller.setCustomMaximumItems(count)
    }
}

enum CaptureRetentionInput {
    static let presets = [10, 20, 50, 100, 200]
    static func parse(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(trimmed), value > 0 else { return nil }
        return value
    }
}
