import AppKit
import Foundation

/// A passive development window. Clicking its controls must not take key focus
/// away from the selected pinned image.
@MainActor
final class CaptureZoomLogPanel: NSPanel {
    var onHide: (() -> Void)?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func close() { orderOut(nil) }
    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        onHide?()
    }
}

/// A bounded pending batch, shared by the display and asynchronous file queues.
struct CaptureZoomLogBuffer {
    struct Batch {
        let lines: [String]
        let dropped: Int
    }
    private let capacity: Int
    private var lines: [String] = []
    private var first = 0
    private var dropped = 0
    var count: Int { lines.count }

    init(capacity: Int = 1000) {
        self.capacity = max(1, capacity)
        lines.reserveCapacity(self.capacity)
    }
    mutating func append(_ line: String) {
        if lines.count < capacity {
            lines.append(line)
        } else {
            lines[first] = line
            first = (first + 1) % capacity
            dropped += 1
        }
    }
    mutating func drain() -> Batch {
        let ordered = first == 0 ? lines : Array(lines[first...]) + Array(lines[..<first])
        let batch = Batch(lines: ordered, dropped: dropped)
        clear()
        return batch
    }
    mutating func clear() {
        lines.removeAll(keepingCapacity: true)
        first = 0
        dropped = 0
    }
}

@MainActor
final class CaptureZoomLiveLog: NSObject {
    static let shared = CaptureZoomLiveLog()
    enum Source: String { case application, native, frame, state }

    var isVisible: Bool { panel?.isVisible == true }
    var isRecording: Bool { recording }
    var fileURL: URL { logURL }

    private let logURL: URL
    private let writer: CaptureZoomLogFileWriter
    private let origin = ProcessInfo.processInfo.systemUptime
    private var panel: CaptureZoomLogPanel?
    private var textView: NSTextView?
    private var scrollView: NSScrollView?
    private var statusLine: NSTextField?
    private var recording = false
    private var timer: Timer?
    private var pending = CaptureZoomLogBuffer()
    private var filePending = CaptureZoomLogBuffer()
    private var fileResetPending = false
    private var fileTask: Task<Void, Never>?
    private var fileRequestedID: UInt64 = 0
    private var fileCompletedID: UInt64 = 0
    private var displayedLengths: [Int] = []
    private var nativeCalls = 0
    private var frames = 0
    private var dropped = 0
    private var fileError: String?
    private let logFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    private override init() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let url = URL(fileURLWithPath: "/tmp/pastes-zoom-live-\(pid).log")
        logURL = url
        let date = ISO8601DateFormatter().string(from: Date())
        writer = CaptureZoomLogFileWriter(url: url, header:
            "# Pastes Dev live zoom log; PID \(pid); origin \(date)\n" +
            "# Relative seconds; [source]; window; message. Recording runs only while this window is open.\n" +
            "# Input: NSMagnificationGestureRecognizer only; magnification is reset after every callback.\n" +
            "# Position trace v10: dispatch -> window received -> responder received; pointer movement never changes zoom.\n" +
            "# mouseDownTargetNow is a current click hit-test, not the target of an ongoing gesture.\n" +
            "# Display and pending queues keep 1000 entries. Messages are limited to 1536 UTF-8 bytes.\n" +
            "# File rotates at 2 MiB; older entries are discarded. No image data is recorded.\n")
        super.init()
    }

    func record(_ source: Source, window: Int = 0, _ message: @autoclosure () -> String) {
        guard AppEnvironment.isDevelopment, recording else { return }
        let prefix = String(decoding: message().utf8.prefix(1536), as: UTF8.self)
        let singleLine = prefix.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ↩ ")
        let bounded = String(decoding: singleLine.utf8.prefix(1536), as: UTF8.self)
        let time = String(format: "+%8.3f", ProcessInfo.processInfo.systemUptime - origin)
        pending.append("\(time) [\(source.rawValue)] window=\(window) \(bounded)")
        switch source {
        case .native: nativeCalls += 1
        case .frame: frames += 1
        default: break
        }
    }

    func show(near: CGRect? = nil) {
        guard AppEnvironment.isDevelopment else { return }
        let window = panel ?? makePanel()
        if !window.isVisible { window.setFrame(preferredFrame(near: near), display: false) }
        window.orderFrontRegardless()
        guard !recording else { return }
        recording = true
        let ticker = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushPending() }
        }
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
        record(.state, "Recording started; input=NSMagnificationGestureRecognizer only; close this window to pause.")
        updateStatus()
    }

    private func makePanel() -> CaptureZoomLogPanel {
        let window = CaptureZoomLogPanel(contentRect: CGRect(x: 0, y: 0, width: 560, height: 350),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = C("缩放实时日志", "Live zoom log")
        window.level = .floating
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.minSize = NSSize(width: 420, height: 240)
        window.onHide = { [weak self] in self?.stopRecording() }

        let content = NSView()
        let buttons = NSStackView(views: [
            button(C("清空", "Clear"), action: #selector(clearLog)),
            button(C("复制", "Copy"), action: #selector(copyLog)),
            button(C("打开日志文件", "Open log file"), action: #selector(openLogFile))
        ])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder
        let text = NSTextView()
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.importsGraphics = false
        text.usesFontPanel = false
        text.font = logFont
        text.textColor = .labelColor
        text.backgroundColor = .textBackgroundColor
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = true
        text.autoresizingMask = [.width]
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = text.maxSize
        text.layoutManager?.allowsNonContiguousLayout = true
        scroll.documentView = text
        for view in [buttons, status, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            buttons.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            status.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8)
        ])
        window.contentView = content
        panel = window
        textView = text
        scrollView = scroll
        statusLine = status
        return window
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12)
        return button
    }

    private func preferredFrame(near: CGRect?) -> CGRect {
        let screen = near.flatMap { image in
            NSScreen.screens.max { Self.overlap($0.visibleFrame, image) < Self.overlap($1.visibleFrame, image) }
        } ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let area = (screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768))
            .insetBy(dx: 12, dy: 12)
        let size = CGSize(width: min(560, area.width), height: min(350, area.height))
        let candidates = [
            CGRect(x: area.maxX - size.width, y: area.maxY - size.height, width: size.width, height: size.height),
            CGRect(x: area.minX, y: area.maxY - size.height, width: size.width, height: size.height),
            CGRect(x: area.maxX - size.width, y: area.minY, width: size.width, height: size.height),
            CGRect(origin: area.origin, size: size)
        ]
        guard let near else { return candidates[0] }
        let avoid = near.insetBy(dx: -20, dy: -20)
        return candidates.min { Self.overlap($0, avoid) < Self.overlap($1, avoid) } ?? candidates[0]
    }

    private static func overlap(_ first: CGRect, _ second: CGRect) -> CGFloat {
        let common = first.intersection(second)
        return common.isNull ? 0 : common.width * common.height
    }

    private func stopRecording() {
        guard recording else { return }
        record(.state, "Recording paused; reopen this window to resume.")
        recording = false
        timer?.invalidate()
        timer = nil
        flushPending()
    }

    private func flushPending() {
        let batch = pending.drain()
        dropped += batch.dropped
        if !batch.lines.isEmpty {
            appendToDisplay(batch.lines)
            for line in batch.lines { filePending.append(line) }
            fileRequestedID += 1
            startFileWrite()
        }
        updateStatus()
    }

    private func appendToDisplay(_ lines: [String]) {
        guard let textView, let storage = textView.textStorage else { return }
        let follow = scrollView.map { textView.bounds.height - $0.contentView.bounds.maxY < 32 } ?? true
        let text = lines.joined(separator: "\n") + "\n"
        displayedLengths.append(contentsOf: lines.map { $0.utf16.count + 1 })
        storage.beginEditing()
        storage.append(NSAttributedString(string: text, attributes: [.font: logFont, .foregroundColor: NSColor.labelColor]))
        let excess = displayedLengths.count - 1000
        if excess > 0 {
            let characters = displayedLengths.prefix(excess).reduce(0, +)
            storage.deleteCharacters(in: NSRange(location: 0, length: characters))
            displayedLengths.removeFirst(excess)
        }
        storage.endEditing()
        if follow { textView.scrollToEndOfDocument(nil) }
    }

    private func startFileWrite() {
        guard fileTask == nil, fileResetPending || filePending.count > 0 else { return }
        let batch = filePending.drain()
        dropped += batch.dropped
        let reset = fileResetPending
        fileResetPending = false
        let requestID = fileRequestedID
        let text = batch.lines.isEmpty ? "" : batch.lines.joined(separator: "\n") + "\n"
        let writer = self.writer
        fileTask = Task { [weak self] in
            let error = await writer.write(text, reset: reset)
            guard let self else { return }
            self.fileTask = nil
            self.fileCompletedID = max(self.fileCompletedID, requestID)
            self.fileError = error
            self.updateStatus()
            self.startFileWrite()
        }
    }

    private func updateStatus() {
        let state = recording ? C("录制中", "Recording") : C("已暂停", "Paused")
        let omitted = dropped > 0 ? " · \(C("丢弃", "Dropped")) \(dropped)" : ""
        let error = fileError.map { " · \(C("写入失败", "Write failed")): \($0)" } ?? ""
        statusLine?.stringValue = "\(state) · \(C("系统捏合", "System pinch")) · native \(nativeCalls) · frame \(frames)\(omitted)\(error)"
    }

    @objc private func clearLog() {
        pending.clear()
        filePending.clear()
        displayedLengths.removeAll(keepingCapacity: true)
        textView?.textStorage?.setAttributedString(NSAttributedString(string: ""))
        nativeCalls = 0
        frames = 0
        dropped = 0
        fileResetPending = true
        fileRequestedID += 1
        startFileWrite()
        updateStatus()
    }

    @objc private func copyLog() {
        flushPending()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView?.string ?? "", forType: .string)
    }

    @objc private func openLogFile() {
        flushPending()
        // A running write can have a reset or a newer batch queued behind it.
        // Wait for this request, rather than only the current in-flight task;
        // later recording must not extend the barrier indefinitely.
        let requestedID = fileRequestedID
        Task { [weak self] in
            guard let self else { return }
            while self.fileCompletedID < requestedID {
                self.startFileWrite()
                guard let task = self.fileTask else { return }
                await task.value
            }
            guard self.fileError == nil else { return }
            NSWorkspace.shared.open(self.fileURL)
        }
    }
}

/// File I/O stays on this actor, away from gesture dispatch and AppKit rendering.
private actor CaptureZoomLogFileWriter {
    private let url: URL
    private let header: String
    private var handle: FileHandle?
    private var bytes = 0
    private let limit = 2 * 1024 * 1024

    init(url: URL, header: String) {
        self.url = url
        self.header = header
    }
    func write(_ text: String, reset: Bool) -> String? {
        do {
            if reset || handle == nil { try resetFile(rotated: false) }
            let data = Data(text.utf8)
            if bytes + data.count > limit { try resetFile(rotated: true) }
            try handle?.write(contentsOf: data)
            bytes += data.count
            return nil
        } catch {
            try? handle?.close()
            handle = nil
            return error.localizedDescription
        }
    }
    private func resetFile(rotated: Bool) throws {
        try handle?.close()
        handle = nil
        let notice = rotated ? "# Rotated at the 2 MiB limit; earlier entries were discarded.\n" : ""
        let data = Data((header + notice).utf8)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        handle = try FileHandle(forWritingTo: url)
        try handle?.seekToEnd()
        bytes = data.count
    }
}
