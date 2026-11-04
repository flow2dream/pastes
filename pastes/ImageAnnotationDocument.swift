import AppKit
import Combine

/// All geometry is in original image pixels (bottom-left origin), independent of window size.
enum AnnotationTool: String, CaseIterable {
    case select, rectangle, ellipse, arrow, pen, text
    var title: String {
        switch self {
        case .select: return C("选择", "Select")
        case .rectangle: return C("矩形", "Rectangle")
        case .ellipse: return C("椭圆", "Ellipse")
        case .arrow: return C("箭头", "Arrow")
        case .pen: return C("画笔", "Pen")
        case .text: return C("文字", "Text")
        }
    }
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .rectangle: return "rectangle"
        case .ellipse: return "oval"
        case .arrow: return "arrow.up.right"
        case .pen: return "pencil.tip"
        case .text: return "textformat"
        }
    }
}

struct ImageAnnotation: Identifiable {
    let id: UUID
    var tool: AnnotationTool
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint]
    var color: NSColor
    var lineWidth: CGFloat
    var text: String
    var bounds: CGRect {
        let all = tool == .pen ? points : [start, end]
        guard let first = all.first else { return .zero }
        return all.dropFirst().reduce(CGRect(origin: first, size: .zero)) { rect, point in
            CGRect(x: min(rect.minX, point.x), y: min(rect.minY, point.y),
                   width: max(rect.maxX, point.x) - min(rect.minX, point.x),
                   height: max(rect.maxY, point.y) - min(rect.minY, point.y))
        }
    }
    func translated(dx: CGFloat, dy: CGFloat) -> ImageAnnotation {
        var copy = self
        copy.start.x += dx; copy.start.y += dy; copy.end.x += dx; copy.end.y += dy
        copy.points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        return copy
    }
    func resized(to rect: CGRect) -> ImageAnnotation {
        let old = bounds
        func convert(_ point: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + (point.x - old.minX) / max(old.width, 0.001) * rect.width,
                    y: rect.minY + (point.y - old.minY) / max(old.height, 0.001) * rect.height)
        }
        var copy = self
        copy.start = convert(start); copy.end = convert(end); copy.points = points.map(convert)
        return copy
    }
    func path() -> NSBezierPath {
        let path: NSBezierPath
        switch tool {
        case .rectangle: path = NSBezierPath(rect: bounds)
        case .ellipse: path = NSBezierPath(ovalIn: bounds)
        case .arrow:
            path = NSBezierPath(); path.move(to: start); path.line(to: end)
            let angle = atan2(end.y - start.y, end.x - start.x)
            let length = min(hypot(end.x - start.x, end.y - start.y) * 0.4, max(14, lineWidth * 4))
            for offset in [-CGFloat.pi / 6, CGFloat.pi / 6] {
                path.move(to: end)
                path.line(to: CGPoint(x: end.x - length * cos(angle + offset), y: end.y - length * sin(angle + offset)))
            }
        case .pen:
            path = NSBezierPath()
            if let first = points.first { path.move(to: first); points.dropFirst().forEach { path.line(to: $0) } }
        default: path = NSBezierPath()
        }
        path.lineWidth = lineWidth; path.lineCapStyle = .round; path.lineJoinStyle = .round
        return path
    }
    func draw() {
        color.setStroke()
        if tool == .text {
            let font = NSFont.systemFont(ofSize: max(10, bounds.height * 0.75), weight: .medium)
            (text as NSString).draw(in: bounds, withAttributes: [.font: font, .foregroundColor: color])
        } else { path().stroke() }
    }
}

@MainActor
final class ImageAnnotationDocument: ObservableObject {
    let image: NSImage
    let pixelSize: CGSize
    @Published var tool: AnnotationTool = .rectangle
    @Published var color: NSColor = .systemRed
    @Published var lineWidth: CGFloat = 4
    @Published private(set) var annotations: [ImageAnnotation] = []
    @Published var selection: UUID?
    @Published private(set) var revision = 0
    private var undoStack: [[ImageAnnotation]] = []
    private var redoStack: [[ImageAnnotation]] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var hasChanges: Bool { !annotations.isEmpty }

    convenience init(url: URL) throws { try self.init(data: Data(contentsOf: url)) }
    init(data: Data) throws {
        guard let bitmap = NSBitmapImageRep(data: data), bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { throw CaptureError.invalidMedia }
        pixelSize = CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        image = NSImage(size: pixelSize)
        image.addRepresentation(bitmap)
    }
    func add(_ annotation: ImageAnnotation) {
        checkpoint(); annotations.append(annotation); selection = annotation.id; revision += 1
    }
    func replace(_ annotation: ImageAnnotation) {
        guard annotations.contains(where: { $0.id == annotation.id }) else { return }
        checkpoint(); annotations = annotations.map { $0.id == annotation.id ? annotation : $0 }; revision += 1
    }
    func setColor(_ value: NSColor) {
        color = value
        if var selected = annotations.first(where: { $0.id == selection }), tool == .select {
            selected.color = value; replace(selected)
        }
    }
    func setLineWidth(_ value: CGFloat) {
        lineWidth = value
        if var selected = annotations.first(where: { $0.id == selection }), tool == .select {
            selected.lineWidth = value; replace(selected)
        }
    }
    func deleteSelected() {
        guard let selection, annotations.contains(where: { $0.id == selection }) else { return }
        checkpoint(); annotations.removeAll { $0.id == selection }; self.selection = nil; revision += 1
    }
    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations); annotations = previous; selection = nil; revision += 1
    }
    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations); annotations = next; selection = nil; revision += 1
    }
    private func checkpoint() { undoStack.append(annotations); redoStack.removeAll() }

    func exportPNG() throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixelSize.width), pixelsHigh: Int(pixelSize.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CaptureError.invalidMedia }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: CGRect(origin: .zero, size: pixelSize), from: .zero, operation: .copy, fraction: 1)
        for annotation in annotations { annotation.draw() }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CaptureError.invalidMedia }
        return png
    }
}
