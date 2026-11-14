// Renders the CcinnRedis app icon (all macOS iconset sizes) with AppKit:
// a crimson-to-plum squircle, three "memory" bars and a white bolt.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(1)
}
let outputDirectory = URL(fileURLWithPath: arguments[1])
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func renderIcon(pixels: Int) -> Data? {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let scale = CGFloat(pixels) / 1024
    let body = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    let radius = 186 * scale

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 28 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -12 * scale)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    NSColor(srgbRed: 0.45, green: 0.08, blue: 0.24, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.96, green: 0.38, blue: 0.40, alpha: 1),
        NSColor(srgbRed: 0.66, green: 0.12, blue: 0.30, alpha: 1),
        NSColor(srgbRed: 0.30, green: 0.07, blue: 0.27, alpha: 1),
    ], atLocations: [0, 0.55, 1], colorSpace: .sRGB)
    gradient?.draw(in: shape, angle: -55)

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    let highlight = NSGradient(colors: [NSColor.white.withAlphaComponent(0.20), NSColor.white.withAlphaComponent(0)])
    highlight?.draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Three rounded "memory" bars.
    for index in 0..<3 {
        let width = (460 - CGFloat(index) * 50) * scale
        let rect = NSRect(x: body.midX - width / 2, y: (300 - CGFloat(index) * 62) * scale, width: width, height: 40 * scale)
        NSColor.white.withAlphaComponent(0.22 + CGFloat(index) * 0.12).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 20 * scale, yRadius: 20 * scale).fill()
    }

    let configuration = NSImage.SymbolConfiguration(pointSize: 420 * scale, weight: .bold)
    if let symbol = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let glyphShadow = NSShadow()
        glyphShadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        glyphShadow.shadowBlurRadius = 18 * scale
        glyphShadow.shadowOffset = NSSize(width: 0, height: -8 * scale)
        NSGraphicsContext.saveGraphicsState()
        glyphShadow.set()
        let size = tinted.size
        tinted.draw(in: NSRect(x: body.midX - size.width / 2, y: body.midY - size.height / 2 + 70 * scale, width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()
    }
    return bitmap.representation(using: .png, properties: [:])
}

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in sizes {
    guard let data = renderIcon(pixels: pixels) else { continue }
    try data.write(to: outputDirectory.appendingPathComponent("\(name).png"))
}
print("Wrote \(sizes.count) icons to \(outputDirectory.path)")
