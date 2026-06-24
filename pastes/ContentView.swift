//
//  ContentView.swift
//  pastes
//
//  Created by hai on 2026/6/17.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ClipboardItem.timestamp, order: .reverse) private var items: [ClipboardItem]
    @State private var searchText = ""
    @State private var monitor = ClipboardMonitor()
    @State private var copiedItemId: PersistentIdentifier?
    @State private var hoveredItemId: PersistentIdentifier?
    @State private var isPanelPinned = false
    var onOpenSettings: (() -> Void)?
    var onPaste: (() -> Void)?
    var onTogglePin: (() -> Bool)?

    private var filteredItems: [ClipboardItem] {
        if searchText.isEmpty { return items }
        return items.filter { $0.content.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            searchBar
            clipboardList
        }
        .frame(minWidth: 420, minHeight: 500)
        .onAppear {
            monitor.start { text, rtfData in
                addClipboardItem(text, rtfData: rtfData)
            }
            monitor.onCopyImage = { data in
                addClipboardImage(data)
            }
        }
        .onDisappear {
            monitor.stop()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Image(systemName: "clipboard.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(L("app_name"))
                .font(.title2.bold())
            Spacer()
            Text(String(format: L("items_count"), items.count))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(role: .destructive) {
                clearAll()
            } label: {
                Image(systemName: "trash")
                    .font(.body)
            }
            .buttonStyle(.borderless)
            .disabled(items.isEmpty)
            Button {
                if let result = onTogglePin?() {
                    isPanelPinned = result
                }
            } label: {
                Image(systemName: isPanelPinned ? "pin.fill" : "pin")
                    .font(.body)
                    .foregroundStyle(isPanelPinned ? .red : .secondary)
            }
            .buttonStyle(.borderless)
            .help(isPanelPinned ? L("unpin_panel") : L("pin_panel"))
            Button {
                onOpenSettings?()
            } label: {
                Image(systemName: "gear")
                    .font(.body)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(L("search_placeholder"), text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - List

    private var sortedItems: [ClipboardItem] {
        filteredItems.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.timestamp > rhs.timestamp
        }
    }

    private var clipboardList: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                if filteredItems.isEmpty {
                    emptyState
                } else {
                    ForEach(sortedItems) { item in
                        clipboardRow(item)
                    }
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clipboard")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(searchText.isEmpty ? L("empty_title") : L("empty_search"))
                .font(.headline)
                .foregroundStyle(.secondary)
            if searchText.isEmpty {
                Text(L("empty_hint"))
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    // MARK: - Row

    private func clipboardRow(_ item: ClipboardItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // Pin indicator stripe
            if item.isPinned {
                RoundedRectangle(cornerRadius: 2)
                    .fill(
                        LinearGradient(
                            colors: [.red, .red.opacity(0.6)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 3)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if item.isImage, let data = item.imageData, let nsImage = NSImage(data: data) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    } else {
                        Text(item.content)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(3)
                    }
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.red)
                            .rotationEffect(.degrees(45))
                    }
                }
                Text(item.timestamp, format: .dateTime.hour().minute().second())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(spacing: 6) {
                Button {
                    togglePin(item)
                } label: {
                    Image(systemName: item.isPinned ? "pin.slash.fill" : "pin")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(item.isPinned ? .red : .secondary)
                        .frame(width: 28, height: 28)
                        .background(item.isPinned ? Color.red.opacity(0.15) : Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(item.isPinned ? L("unpin") : L("pin"))

                Button(role: .destructive) {
                    deleteItem(item)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(L("delete"))
            }
        }
        .padding(10)
        .background {
            if hoveredItemId == item.persistentModelID {
                Color.accentColor.opacity(0.18)
            } else if item.isPinned {
                Color.red.opacity(0.06)
            } else {
                Color(nsColor: .controlBackgroundColor).opacity(0.5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    hoveredItemId == item.persistentModelID ? Color.accentColor.opacity(0.4) :
                    item.isPinned ? Color.red.opacity(0.25) : .clear,
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredItemId = hovering ? item.persistentModelID : nil
            }
        }
        .onTapGesture {
            copyItem(item)
        }
        .contextMenu {
            Button(L("context_copy")) { copyItem(item) }
            Button(item.isPinned ? L("context_unpin") : L("context_pin")) { togglePin(item) }
            Divider()
            Button(L("context_delete"), role: .destructive) { deleteItem(item) }
        }
    }

    // MARK: - Actions

    @AppStorage("maxClipboardItems") private var maxItems = 20

    private func addClipboardItem(_ text: String, rtfData: Data? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let existing = items.first(where: { $0.content == trimmed && !$0.isImage }) {
            existing.timestamp = Date()
            if rtfData != nil { existing.rtfData = rtfData }
            try? modelContext.save()
            return
        }
        let item = ClipboardItem(content: trimmed, rtfData: rtfData)
        modelContext.insert(item)
        enforceLimit()
        try? modelContext.save()
    }

    private func addClipboardImage(_ data: Data) {
        let item = ClipboardItem(content: "[Image]", imageData: data)
        modelContext.insert(item)
        enforceLimit()
        try? modelContext.save()
    }

    private func enforceLimit() {
        guard maxItems > 0 else { return }
        let unpinned = items.filter { !$0.isPinned }.sorted { $0.timestamp < $1.timestamp }
        let overCount = items.count - maxItems
        guard overCount > 0 else { return }
        for i in 0..<min(overCount, unpinned.count) {
            modelContext.delete(unpinned[i])
        }
    }

    private func copyItem(_ item: ClipboardItem) {
        monitor.isCopying = true
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if item.isImage, let data = item.imageData {
            pasteboard.setData(data, forType: .tiff)
        } else if let rtfData = item.rtfData {
            pasteboard.setData(rtfData, forType: .rtf)
            pasteboard.setString(item.content, forType: .string)
        } else {
            pasteboard.setString(item.content, forType: .string)
        }
        copiedItemId = item.persistentModelID
        onPaste?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if copiedItemId == item.persistentModelID {
                copiedItemId = nil
            }
        }
    }

    private func togglePin(_ item: ClipboardItem) {
        withAnimation(.easeInOut(duration: 0.2)) {
            item.isPinned.toggle()
            try? modelContext.save()
        }
    }

    private func deleteItem(_ item: ClipboardItem) {
        withAnimation {
            modelContext.delete(item)
            try? modelContext.save()
        }
    }

    private func clearAll() {
        withAnimation {
            for item in items where !item.isPinned {
                modelContext.delete(item)
            }
            try? modelContext.save()
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: ClipboardItem.self, inMemory: true)
}
