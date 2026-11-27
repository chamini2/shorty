// Draws the app icon: the menu bar cup, full and steaming, in white on a
// charcoal tile. Built and run by Packaging/make-icon.sh, together with
// Sources/Shorty/CupGlyph.swift, so the icon is the menu bar cup itself.
//
// Usage: make-icon OUTPUT.icns

import AppKit

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: make-icon OUTPUT.icns")
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])

let canvas: CGFloat = 1024

/// The macOS icon grid: an 824 point tile centred on the 1024 canvas, which
/// leaves the margin the system expects for the shadow.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tileRadius: CGFloat = 185

let ink = NSColor(srgbRed: 250 / 255, green: 250 / 255, blue: 250 / 255, alpha: 1)
let charcoal = NSColor(srgbRed: 30 / 255, green: 30 / 255, blue: 32 / 255, alpha: 1)

/// The cup on its own clear layer, since the glyph cuts its gaps out of what
/// is under it. Drawn lazily, so it renders at each bitmap's resolution.
let cup = NSImage(size: CupGlyph.designBounds.size, flipped: false) { rect in
    CupGlyph.draw(in: rect, filled: true, color: ink)
    return true
}

func drawTile() {
    let shape = NSBezierPath(roundedRect: tile, xRadius: tileRadius, yRadius: tileRadius)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 24
    shadow.set()
    charcoal.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
}

func render(pixels: Int) -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("Could not allocate a \(pixels) pixel bitmap")
    }
    bitmap.size = NSSize(width: canvas, height: canvas)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high

    drawTile()
    cup.draw(in: CupGlyph.designBounds)

    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode a \(pixels) pixel PNG")
    }
    return png
}

let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("Shorty-\(ProcessInfo.processInfo.processIdentifier).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for size in [16, 32, 128, 256, 512] {
    try render(pixels: size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(pixels: size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output", output.path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(iconutil.terminationStatus)")
}
