import AppKit
import Testing
@testable import pastes

@Suite("Live zoom log")
struct CaptureZoomLiveLogTests {
    @Test @MainActor
    func overflowingPendingBatchKeepsTheNewestLinesInOrderAndReportsOmissions() {
        var buffer = CaptureZoomLogBuffer(capacity: 3)
        for line in ["first", "second", "third", "fourth", "fifth"] { buffer.append(line) }
        #expect(buffer.count == 3)
        let batch = buffer.drain()
        #expect(batch.lines == ["third", "fourth", "fifth"])
        #expect(batch.dropped == 2)
        #expect(buffer.count == 0)
        buffer.append("next session")
        let next = buffer.drain()
        #expect(next.lines == ["next session"] && next.dropped == 0)
    }

    @Test @MainActor
    func clearingPendingLinesDoesNotLeakThemIntoTheNextBatch() {
        var buffer = CaptureZoomLogBuffer(capacity: 2)
        for line in ["first", "second", "third"] { buffer.append(line) }
        buffer.clear()
        let empty = buffer.drain()
        #expect(empty.lines.isEmpty && empty.dropped == 0)
        buffer.append("fresh")
        let fresh = buffer.drain()
        #expect(fresh.lines == ["fresh"])
    }

    @Test @MainActor
    func logPanelCannotTakeKeyOrMainFocusAndClosingKeepsItsContentForReopening() {
        let panel = CaptureZoomLogPanel(contentRect: CGRect(x: -10000, y: -10000, width: 500, height: 300),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let content = NSView()
        panel.contentView = content
        let previousKey = NSApplication.shared.keyWindow
        var hidden = 0
        panel.onHide = { hidden += 1 }
        #expect(!panel.canBecomeKey && !panel.canBecomeMain)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        panel.close()
        #expect(hidden == 1 && !panel.isVisible)
        #expect(panel.contentView === content)
        #expect(NSApplication.shared.keyWindow === previousKey)
    }
}
