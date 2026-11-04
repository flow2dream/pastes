import AppKit
import Combine
import SwiftUI

struct AnnotationCanvasHost: NSViewRepresentable {
    @ObservedObject var document: ImageAnnotationDocument
    func makeNSView(context: Context) -> ImageAnnotationCanvas { ImageAnnotationCanvas(document: document) }
    func updateNSView(_ view: ImageAnnotationCanvas, context: Context) { view.needsDisplay = true }
}

@MainActor
final class ImageAnnotationCanvas: NSView {
    let document: ImageAnnotationDocument
    var edgeToEdge = false
    var onEscape: (() -> Void)?
    private var draft: ImageAnnotation?
    private var origin: CGPoint?
    private var original: ImageAnnotation?
    private var resizeCorner: Int?
    private var gestureTool: AnnotationTool?
    private var subscription: AnyCancellable?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init(document: ImageAnnotationDocument) {
        self.document = document
        super.init(frame: .zero)
        subscription = document.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.needsDisplay = true }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    static func fittedRect(image: CGSize, bounds: CGRect) -> CGRect {
        let area = bounds.insetBy(dx: 24, dy: 24)
        let scale = max(0.001, min(max(1, area.width) / image.width, max(1, area.height) / image.height))
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    var imageRect: CGRect { edgeToEdge ? bounds : Self.fittedRect(image: document.pixelSize, bounds: bounds) }
    private var scale: CGFloat { imageRect.width / document.pixelSize.width }
    func imagePoint(_ point: CGPoint, clamp: Bool) -> CGPoint? {
        let rect = imageRect
        guard clamp || rect.contains(point) else { return nil }
        return CGPoint(x: min(document.pixelSize.width, max(0, (point.x - rect.minX) / scale)),
                       y: min(document.pixelSize.height, max(0, (point.y - rect.minY) / scale)))
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        NSGraphicsContext.saveGraphicsState()
        let transform = AffineTransform(translationByX: imageRect.minX, byY: imageRect.minY)
        (transform as NSAffineTransform).concat()
        let zoom = NSAffineTransform(); zoom.scale(by: scale); zoom.concat()
        NSBezierPath(rect: CGRect(origin: .zero, size: document.pixelSize)).addClip()
        document.image.draw(in: CGRect(origin: .zero, size: document.pixelSize))
        for annotation in document.annotations where annotation.id != draft?.id { annotation.draw() }
        draft?.draw()
        if let selected = draft ?? document.annotations.first(where: { $0.id == document.selection }), document.tool == .select {
            let rect = selected.bounds
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(rect: rect); outline.lineWidth = 1 / scale
            outline.setLineDash([4 / scale, 3 / scale], count: 2, phase: 0); outline.stroke()
            for point in corners(rect) {
                let handle = NSBezierPath(rect: CGRect(x: point.x - 4 / scale, y: point.y - 4 / scale, width: 8 / scale, height: 8 / scale))
                NSColor.white.setFill(); handle.fill(); NSColor.controlAccentColor.setStroke(); handle.lineWidth = 1 / scale; handle.stroke()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    private func corners(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let point = imagePoint(convert(event.locationInWindow, from: nil), clamp: false) else { document.selection = nil; return }
        begin(at: point)
    }
    func begin(at point: CGPoint) {
        cancelGesture()
        origin = point; gestureTool = document.tool
        if document.tool == .select {
            if let selected = document.annotations.first(where: { $0.id == document.selection }),
               let corner = corners(selected.bounds).firstIndex(where: { hypot($0.x - point.x, $0.y - point.y) <= 9 / scale }) {
                original = selected; resizeCorner = corner; return
            }
            let hit = document.annotations.reversed().first { $0.bounds.insetBy(dx: -7 / scale, dy: -7 / scale).contains(point) }
            document.selection = hit?.id; original = hit
        } else if document.tool == .text {
            addText(at: point); cancelGesture()
        } else {
            document.selection = nil
            draft = ImageAnnotation(id: UUID(), tool: document.tool, start: point, end: point,
                points: [point], color: document.color, lineWidth: document.lineWidth, text: "")
        }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let point = imagePoint(convert(event.locationInWindow, from: nil), clamp: true) else { return }
        drag(to: point)
    }
    func drag(to point: CGPoint) {
        guard let origin else { return }
        if let original {
            if let resizeCorner {
                let opposite = corners(original.bounds)[(resizeCorner + 2) % 4]
                let rect = CGRect(x: min(point.x, opposite.x), y: min(point.y, opposite.y), width: max(1, abs(point.x - opposite.x)), height: max(1, abs(point.y - opposite.y)))
                draft = original.resized(to: rect)
            } else {
                let dx = min(document.pixelSize.width - original.bounds.maxX, max(-original.bounds.minX, point.x - origin.x))
                let dy = min(document.pixelSize.height - original.bounds.maxY, max(-original.bounds.minY, point.y - origin.y))
                draft = original.translated(dx: dx, dy: dy)
            }
        } else if draft != nil {
            draft?.end = point
            if gestureTool == .pen { draft?.points.append(point) }
        }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if let point = imagePoint(convert(event.locationInWindow, from: nil), clamp: true), origin != nil { drag(to: point) }
        end()
    }
    func end() {
        if let draft {
            if original != nil { document.replace(draft) }
            else if hypot(draft.end.x - draft.start.x, draft.end.y - draft.start.y) * scale >= 3 || (draft.tool == .pen && draft.points.count > 3) {
                document.add(draft)
            }
        }
        cancelGesture()
    }
    func cancelGesture() {
        draft = nil; origin = nil; original = nil; resizeCorner = nil; gestureTool = nil; needsDisplay = true
    }
    private func addText(at point: CGPoint) {
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = C("添加文字", "Add text")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
        alert.accessoryView = input
        alert.addButton(withTitle: C("添加", "Add")); alert.addButton(withTitle: C("取消", "Cancel"))
        alert.window.initialFirstResponder = input
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, !input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let fontSize = max(20, self.document.lineWidth * 6)
            let measured = (input.stringValue as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium)])
            let height = min(fontSize / 0.75, self.document.pixelSize.height)
            let width = min(measured.width + 8, self.document.pixelSize.width)
            let start = CGPoint(x: min(point.x, self.document.pixelSize.width - width), y: min(point.y, self.document.pixelSize.height - height))
            self.document.add(ImageAnnotation(id: UUID(), tool: .text, start: start, end: CGPoint(x: start.x + width, y: start.y + height),
                points: [], color: self.document.color, lineWidth: self.document.lineWidth, text: input.stringValue))
        }
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
            cancelGesture()
            if event.modifierFlags.contains(.shift) { document.redo() } else { document.undo() }
        } else if event.keyCode == 51 || event.keyCode == 117 { cancelGesture(); document.deleteSelected() }
        else if event.keyCode == 53 { cancelGesture(); document.selection = nil; onEscape?() }
        else { super.keyDown(with: event) }
    }
}
