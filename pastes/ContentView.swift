import SwiftUI

struct ContentView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject private var hotkeyManager = HotkeyManager.shared
    @ObservedObject private var pasteFeedback = PasteFeedback.shared
    @AppStorage("appLanguage") private var language: AppLanguage = .zh
    @AppStorage("captureShelfEnabled") private var captureShelfEnabled = false
    @AppStorage("captureHideImagesInHistory") private var hideImagesInHistory = true
    @AppStorage("maxClipboardItems") private var maxItems = 20
    @ViewState private var searchText = ""
    @ObservedObject var session: ClipboardSession
    @ViewState private var storageError: String?
    @ViewState private var errorTitle = L("storage_error_title")
    @ViewState private var isPanelPinned = false

    // Offline visual previews must not observe the system clipboard.
    var monitoringEnabled = true
    var onOpenSettings: (() -> Void)?
    var onPaste: (() -> Void)?
    var onTogglePin: (() -> Bool)?
    var onDismiss: (() -> Void)?

    static func historyItems(_ items: [ClipboardItem], shelfEnabled: Bool, hideImages: Bool) -> [ClipboardItem] {
        items.filter { !(shelfEnabled && hideImages && $0.isImage) }
    }

    private var visibleItems: [ClipboardItem] {
        Self.historyItems(store.items, shelfEnabled: captureShelfEnabled, hideImages: hideImagesInHistory)
    }

    private var filteredItems: [ClipboardItem] {
        guard !searchText.isEmpty else { return visibleItems }
        return visibleItems.filter { $0.content.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if pasteFeedback.needsPermission {
                HStack(spacing: 10) {
                    Text(L("paste_permission_required"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(L("paste_permission_settings")) { onOpenSettings?() }
                        .buttonStyle(PastesGlassButtonStyle(prominence: .accent, compact: true))
                }
                .padding(.horizontal, 17)
                .padding(.vertical, 10)
            }
            clipboardList
            footer
        }
        .background(PastesWindowBackground())
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .ignoresSafeArea(.container, edges: .top)
        .environment(\.locale, Locale(identifier: language.rawValue))
        .frame(minWidth: 480, minHeight: 480)

        .onReceive(session.$errorMessage) { message in
            if let message { errorTitle = L("storage_error_title"); storageError = message; session.errorMessage = nil }
        }
        .onExitCommand {
            if searchText.isEmpty {
                onDismiss?()
            } else {
                searchText = ""
            }
        }
        .alert(errorTitle, isPresented: Binding(
            get: { storageError != nil },
            set: { if !$0 { storageError = nil } }
        )) {
            Button(L("no_update_ok")) { storageError = nil }
        } message: {
            Text(storageError ?? "")
        }
    }

    private var searchBar: some View {
        VStack(spacing: 13) {
            HStack(spacing: 11) {
                PastesGlassIcon(symbol: "clipboard.fill", size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pastes")
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                    Text(C("剪贴板历史", "Clipboard history"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if AppEnvironment.isDevelopment {
                    Text("DEV").font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.orange).padding(.horizontal, 7).padding(.vertical, 4)
                        .pastesGlass(cornerRadius: 100, tint: .orange.opacity(0.08))
                }
                Spacer()
                QuietIconButton(
                    symbol: isPanelPinned ? "pin.fill" : "pin",
                    label: L(isPanelPinned ? "unpin_panel" : "pin_panel"),
                    isActive: isPanelPinned
                ) {
                    if let result = onTogglePin?() { isPanelPinned = result }
                }
                QuietIconButton(symbol: "slider.horizontal.3", label: L("settings_title")) {
                    onOpenSettings?()
                }
            }
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                TextField(L("search_placeholder"), text: $searchText)
                    .font(.system(size: 13))
                    .textFieldStyle(.plain)
                    .accessibilityLabel(L("search_placeholder"))
                if !searchText.isEmpty {
                    QuietIconButton(symbol: "xmark", label: L("clear_search"), compact: true) {
                        searchText = ""
                    }
                }
            }
            .padding(.horizontal, 13)
            .frame(height: 39)
            .pastesGlass(cornerRadius: 100)
        }
        .padding(.horizontal, 18)
        .padding(.top, 17)
        .padding(.bottom, 9)
    }

    private var clipboardList: some View {
        let pinned = filteredItems.filter(\.isPinned)
        let recent = filteredItems.filter { !$0.isPinned }

        return ScrollView {
            if filteredItems.isEmpty {
                emptyState
            } else {
                LazyVStack(alignment: .leading, spacing: 7) {
                    if !pinned.isEmpty {
                        sectionLabel(L("history_pinned"), count: pinned.count)
                        rows(pinned)
                    }
                    if !recent.isEmpty {
                        sectionLabel(L("history_recent"), count: recent.count)
                            .padding(.top, pinned.isEmpty ? 0 : 8)
                        rows(recent)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 5)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionLabel(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.white.opacity(0.12), in: Capsule())
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 25, alignment: .leading)
    }

    private func rows(_ items: [ClipboardItem]) -> some View {
        ForEach(items) { item in
            ClipboardRecordRow(
                item: item,
                onCopy: { copyItem(item) },
                onTogglePin: { performStorageChange { try store.togglePin(id: item.id) } },
                onDelete: { performStorageChange { try store.delete(id: item.id) } }
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            PastesGlassIcon(symbol: searchText.isEmpty ? "clipboard" : "magnifyingglass", size: 64)
                .padding(.bottom, 8)
            Text(L(searchText.isEmpty ? "empty_title" : "empty_search"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text(L(searchText.isEmpty ? "empty_hint" : "empty_search_hint"))
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 285)
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Text(String(format: L("items_count"), visibleItems.count))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            QuietIconButton(symbol: "trash", label: L("clear_unpinned"), compact: true, role: .destructive) {
                performStorageChange { try store.clearUnpinned() }
            }
            .disabled(!store.items.contains { !$0.isPinned })

            Spacer()

            Text(L("history_copy_hint"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Text(hotkeyManager.displayString)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .pastesGlass(cornerRadius: 100)
                .help(L("hotkey_title"))
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .pastesGlass(cornerRadius: 100)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private func copyItem(_ item: ClipboardItem) {
        do {
            let generation = try session.copy(item)
            PasteTrace.record("copy_written", details: ["generation": generation])
            onPaste?()
        } catch {
            let failure = error as NSError
            PasteTrace.record("copy_failed", details: ["code": failure.code, "description": failure.localizedDescription])
            errorTitle = L("clipboard_error_title")
            storageError = error.localizedDescription
        }
    }

    private func performStorageChange(_ change: () throws -> Void) {
        do {
            try change()
        } catch {
            errorTitle = L("storage_error_title")
            storageError = error.localizedDescription
        }
    }
}

private struct ClipboardRecordRow: View {
    let item: ClipboardItem
    let onCopy: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void
    @ViewState private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var typeLabel: String {
        L(item.isImage ? "record_image" : item.rtfData != nil ? "record_rich_text" : "record_text")
    }

    var body: some View {
        HStack(spacing: 12) {
            thumbnail

            VStack(alignment: .leading, spacing: 5) {
                Text(item.isImage ? L("record_image") : item.content)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineSpacing(2)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 7) {
                    Text(typeLabel)
                    Text("·")
                        .foregroundStyle(.quaternary)
                    Text(item.timestamp, format: .dateTime.hour().minute())
                        .monospacedDigit()
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 5) {
                QuietIconButton(
                    symbol: item.isPinned ? "pin.slash" : "pin",
                    label: L(item.isPinned ? "unpin" : "pin"),
                    isActive: item.isPinned,
                    action: onTogglePin
                )
                QuietIconButton(symbol: "xmark", label: L("delete"), role: .destructive, action: onDelete)
            }
            .opacity(isHovered ? 1 : item.isPinned ? 0.85 : 0.55)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(minHeight: 74)
        .background {
            let shape = RoundedRectangle(cornerRadius: 23, style: .continuous)
            shape
                .fill(reduceTransparency ? Color(nsColor: .controlBackgroundColor)
                      : Color.white.opacity(scheme == .dark ? 0.065 : 0.25))
                .overlay {
                    shape.fill(LinearGradient(colors: [.white.opacity(0.07), .clear, .black.opacity(0.025)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .overlay {
                    shape.fill(Color.blue.opacity(isHovered ? 0.11 : item.isPinned ? 0.055 : 0))
                }
                .overlay {
                    shape.strokeBorder(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.45 : 0.88),
                                                               .white.opacity(0.10), .white.opacity(0.28)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
                }
                .overlay {
                    if isHovered || contrast == .increased {
                        shape.strokeBorder(Color.blue.opacity(contrast == .increased ? 0.6 : 0.3), lineWidth: 0.8)
                    }
                }
                .shadow(color: .black.opacity(0.025), radius: 6, y: 3)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isHovered)
        .contentShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onCopy)
        .contextMenu {
            Button(L("context_copy"), action: onCopy)
            Button(L(item.isPinned ? "context_unpin" : "context_pin"), action: onTogglePin)
            Divider()
            Button(L("context_delete"), role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if item.isImage, let data = item.imageData, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(.white.opacity(0.7), lineWidth: 0.7)
                }
        } else {
            PastesGlassIcon(symbol: item.rtfData != nil ? "textformat" : "doc.text.fill",
                            tint: item.rtfData != nil ? .purple : .blue, size: 42)
        }
    }
}

private struct QuietIconButton: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let symbol: String
    let label: String
    var isActive = false
    var compact = false
    var role: ButtonRole?
    let action: () -> Void
    @ViewState private var isHovered = false

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 11 : 12, weight: .medium))
                .foregroundStyle(isActive ? .blue : role == .destructive && isHovered ? Color.red : Color.secondary)
                .frame(width: compact ? 25 : 31, height: compact ? 25 : 31)
                .background {
                    Circle()
                        .fill(reduceTransparency ? Color(nsColor: .controlBackgroundColor)
                              : Color.white.opacity(scheme == .dark ? 0.08 : 0.38))
                        .overlay {
                            Circle().fill(isActive ? Color.blue.opacity(0.13) : Color.primary.opacity(isHovered ? 0.06 : 0))
                        }
                        .overlay {
                            Circle().strokeBorder(.white.opacity(isHovered || isActive ? 0.65 : 0.28), lineWidth: 0.7)
                        }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { isHovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}
