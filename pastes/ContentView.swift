import SwiftUI

struct ContentView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject private var hotkeyManager = HotkeyManager.shared
    @ObservedObject private var pasteFeedback = PasteFeedback.shared
    @AppStorage("appLanguage") private var language: AppLanguage = .zh
    @AppStorage("maxClipboardItems") private var maxItems = 20
    @ViewState private var searchText = ""
    @ViewState private var monitor: ClipboardMonitor?
    @ViewState private var storageError: String?
    @ViewState private var errorTitle = L("storage_error_title")
    @ViewState private var isPanelPinned = false

    // Offline visual previews must not observe the system clipboard.
    var monitoringEnabled = true
    var onOpenSettings: (() -> Void)?
    var onPaste: (() -> Void)?
    var onTogglePin: (() -> Bool)?
    var onDismiss: (() -> Void)?

    private var filteredItems: [ClipboardItem] {
        guard !searchText.isEmpty else { return store.items }
        return store.items.filter { $0.content.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            if pasteFeedback.needsPermission {
                HStack(spacing: 10) {
                    Text(L("paste_permission_required"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(L("paste_permission_settings")) { onOpenSettings?() }
                        .controlSize(.small)
                }
                .padding(.horizontal, 17)
                .padding(.vertical, 10)
                Divider()
            }
            clipboardList
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea(.container, edges: .top)
        .environment(\.locale, Locale(identifier: language.rawValue))
        .frame(minWidth: 480, minHeight: 480)
        .onAppear(perform: startMonitoring)
        .onDisappear { monitor?.stop() }
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
        HStack(spacing: 11) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(L("search_placeholder"), text: $searchText)
                .font(.system(size: 15))
                .textFieldStyle(.plain)
                .accessibilityLabel(L("search_placeholder"))

            if !searchText.isEmpty {
                QuietIconButton(symbol: "xmark.circle.fill", label: L("clear_search")) {
                    searchText = ""
                }
            }

            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1, height: 16)
                .padding(.horizontal, 2)

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
        .padding(.horizontal, 17)
        .frame(height: 58)
    }

    private var clipboardList: some View {
        let pinned = filteredItems.filter(\.isPinned)
        let recent = filteredItems.filter { !$0.isPinned }

        return ScrollView {
            if filteredItems.isEmpty {
                emptyState
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
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
                .padding(.horizontal, 8)
                .padding(.top, 9)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionLabel(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
            Text("\(count)")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 11)
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
            Image(systemName: searchText.isEmpty ? "clipboard" : "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 5)
            Text(L(searchText.isEmpty ? "empty_title" : "empty_search"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text(L(searchText.isEmpty ? "empty_hint" : "empty_search_hint"))
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 340)
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Text(String(format: L("items_count"), store.items.count))
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
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5)
                }
                .help(L("hotkey_title"))
        }
        .padding(.horizontal, 17)
        .frame(height: 33)
    }

    private func startMonitoring() {
        guard monitoringEnabled else { return }
        if PastePermission.isGranted { pasteFeedback.needsPermission = false }
        let activeMonitor = monitor ?? ClipboardMonitor(pasteboard: AppEnvironment.pasteboard)
        monitor = activeMonitor
        activeMonitor.start { text, rtfData in
            performStorageChange { try store.addText(text, rtfData: rtfData, limit: maxItems) }
        }
        activeMonitor.onCopyImage = { data in
            performStorageChange { try store.addImage(data, limit: maxItems) }
        }
    }

    private func copyItem(_ item: ClipboardItem) {
        guard let monitor else {
            PasteTrace.record("monitor_missing", details: ["monitoringEnabled": monitoringEnabled])
            return
        }
        do {
            let generation = try ClipboardWriter(pasteboard: monitor.pasteboard).write(item)
            PasteTrace.record("copy_written", details: ["generation": generation])
            monitor.acknowledgeOwnWrite(changeCount: generation)
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

    private var typeLabel: String {
        L(item.isImage ? "record_image" : item.rtfData != nil ? "record_rich_text" : "record_text")
    }

    var body: some View {
        HStack(spacing: 12) {
            thumbnail

            VStack(alignment: .leading, spacing: 5) {
                Text(item.isImage ? L("record_image") : item.content)
                    .font(.system(size: 13))
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

            HStack(spacing: 1) {
                QuietIconButton(
                    symbol: item.isPinned ? "pin.slash" : "pin",
                    label: L(item.isPinned ? "unpin" : "pin"),
                    isActive: item.isPinned,
                    action: onTogglePin
                )
                QuietIconButton(symbol: "xmark", label: L("delete"), role: .destructive, action: onDelete)
            }
            .opacity(isHovered ? 1 : item.isPinned ? 0.65 : 0.25)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(minHeight: 60)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(isHovered ? Color.primary.opacity(0.055) : .clear)
        }
        .contentShape(Rectangle())
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
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
        } else {
            Image(systemName: item.rtfData != nil ? "textformat" : "doc.text")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 38, height: 38)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

private struct QuietIconButton: View {
    @Environment(\.isEnabled) private var isEnabled
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
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
                .frame(width: compact ? 21 : 25, height: compact ? 21 : 25)
                .background {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isHovered || isActive ? Color.primary.opacity(0.07) : .clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { isHovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}
