import AppKit
import Foundation

// A source-drawn cartridge and export arrow; no external artwork or fonts.
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: GenerateIcon.swift <output.iconset>\n", stderr)
    exit(1)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func drawIcon(size: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    NSColor(calibratedWhite: 0.105, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 24, y: 24, width: 976, height: 976), xRadius: 216, yRadius: 216).fill()

    let cartridge = NSBezierPath()
    cartridge.move(to: NSPoint(x: 264, y: 248))
    cartridge.line(to: NSPoint(x: 264, y: 750))
    cartridge.curve(to: NSPoint(x: 296, y: 782), controlPoint1: NSPoint(x: 264, y: 771), controlPoint2: NSPoint(x: 275, y: 782))
    cartridge.line(to: NSPoint(x: 552, y: 782))
    cartridge.line(to: NSPoint(x: 648, y: 686))
    cartridge.line(to: NSPoint(x: 648, y: 248))
    cartridge.close()
    NSColor(calibratedWhite: 0.90, alpha: 1).setFill()
    cartridge.fill()

    NSColor(calibratedWhite: 0.105, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 316, y: 514, width: 280, height: 164), xRadius: 20, yRadius: 20).fill()
    for x in stride(from: 324, through: 560, by: 59) {
        NSBezierPath(roundedRect: NSRect(x: x, y: 292, width: 28, height: 96), xRadius: 9, yRadius: 9).fill()
    }

    // Keep the arrow distinct from the cartridge at small Dock sizes.
    NSColor(calibratedWhite: 0.105, alpha: 1).setStroke()
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 518, y: 454))
    arrow.line(to: NSPoint(x: 820, y: 454))
    arrow.move(to: NSPoint(x: 716, y: 558))
    arrow.line(to: NSPoint(x: 820, y: 454))
    arrow.line(to: NSPoint(x: 716, y: 350))
    arrow.lineWidth = 96
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.stroke()
    NSColor(calibratedRed: 0.97, green: 0.69, blue: 0.24, alpha: 1).setStroke()
    arrow.lineWidth = 52
    arrow.stroke()

    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let file = output.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        try drawIcon(size: points * scale).write(to: file)
    }
}
