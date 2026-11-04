import AppKit

// Work only on the staging iconset; never modify the production icon assets.
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where url.pathExtension == "png" {
    guard let original = NSImage(contentsOf: url), let source = NSBitmapImageRep(data: try Data(contentsOf: url)) else { continue }
    let size = CGFloat(source.pixelsWide)
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    original.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    let badge = NSRect(x: size * 0.08, y: size * 0.07, width: size * 0.84, height: size * 0.28)
    NSColor.systemOrange.setFill()
    NSBezierPath(roundedRect: badge, xRadius: size * 0.05, yRadius: size * 0.05).fill()
    let text = "DEV" as NSString
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: size * 0.22), .foregroundColor: NSColor.black]
    let textSize = text.size(withAttributes: attributes)
    text.draw(at: NSPoint(x: badge.midX - textSize.width / 2, y: badge.midY - textSize.height / 2), withAttributes: attributes)
    NSGraphicsContext.restoreGraphicsState()
    if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: url) }
}
