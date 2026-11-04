import CoreGraphics

/// Geometry in the shelf's top-left coordinate space. The transparent window
/// is deliberately taller than the photos; its blank lower area is not a target.
struct CaptureShelfInteractionRegion {
    let bounds: CGRect
    private let photos: [CGRect]
    private let controls: [CGRect]
    private let row: CGRect

    init(bounds: CGRect, photoRects: [CGRect], controlRects: [CGRect], topCorridorMinY: CGFloat = 0) {
        self.bounds = bounds
        photos = photoRects.map { $0.intersection(bounds) }.filter { !$0.isNull && !$0.isEmpty }
        controls = controlRects.map { $0.intersection(bounds) }.filter { !$0.isNull && !$0.isEmpty }
        // With no photos, the topmost control is the empty shelf's capture pill.
        let bottom = photos.map(\.maxY).max() ?? controls.min(by: { $0.minY < $1.minY })?.maxY ?? bounds.minY
        row = bottom > bounds.minY
            ? CGRect(x: bounds.minX, y: topCorridorMinY, width: bounds.width,
                     height: min(bounds.maxY, bottom + 6) - topCorridorMinY)
            : .zero
    }

    func keepsOpen(at point: CGPoint) -> Bool {
        row.contains(point) || (bounds.contains(point) && controls.contains { $0.insetBy(dx: -6, dy: -6).contains(point) })
    }

    func receivesMouse(at point: CGPoint, scrolling: Bool) -> Bool {
        guard bounds.contains(point) else { return false }
        return controls.contains { $0.insetBy(dx: -6, dy: -6).contains(point) }
            || photos.contains { $0.insetBy(dx: -8, dy: -8).contains(point) }
            || (scrolling && row.contains(point))
    }
}
