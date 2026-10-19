// baseline-guard:allow one-off icon generator for this named app
import AppKit
import Foundation

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "icon_1024.png"

let size = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    FileHandle.standardError.write(Data("cannot allocate bitmap\n".utf8))
    exit(1)
}
rep.size = NSSize(width: size, height: size)

NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
NSGraphicsContext.current = context
let cg = context.cgContext
cg.setAllowsAntialiasing(true)

let canvas = CGRect(x: 0, y: 0, width: size, height: size)
cg.clear(canvas)

// macOS icon grid: 824pt squircle centred in 1024.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 185
let squircle = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

// Soft ambient drop shadow.
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 34,
             color: NSColor.black.withAlphaComponent(0.34).cgColor)
NSColor(calibratedRed: 0.06, green: 0.18, blue: 0.32, alpha: 1).setFill()
squircle.fill()
cg.restoreGState()

// Vertical indigo → teal gradient.
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.09, green: 0.20, blue: 0.42, alpha: 1),
    NSColor(calibratedRed: 0.05, green: 0.40, blue: 0.53, alpha: 1),
    NSColor(calibratedRed: 0.06, green: 0.66, blue: 0.60, alpha: 1)
])!
gradient.draw(in: squircle, angle: 270)

// Edge highlight + soft inner shade for depth.
NSGraphicsContext.saveGraphicsState()
squircle.addClip()
NSColor.white.withAlphaComponent(0.20).setStroke()
let innerEdge = NSBezierPath(roundedRect: tile.insetBy(dx: 5, dy: 5),
                             xRadius: radius - 4, yRadius: radius - 4)
innerEdge.lineWidth = 3
innerEdge.stroke()

let shade = NSBezierPath(rect: NSRect(x: 100, y: 100, width: 824, height: 70))
NSColor.black.withAlphaComponent(0.10).setFill()
shade.fill()
NSGraphicsContext.restoreGraphicsState()

// House silhouette.
let roof = NSBezierPath()
roof.move(to: NSPoint(x: 512, y: 776))
roof.line(to: NSPoint(x: 330, y: 604))
roof.line(to: NSPoint(x: 694, y: 604))
roof.close()
roof.lineJoinStyle = .round

let body = NSBezierPath(roundedRect: NSRect(x: 372, y: 312, width: 280, height: 300),
                        xRadius: 38, yRadius: 38)

cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -6), blur: 14,
             color: NSColor.black.withAlphaComponent(0.18).cgColor)
NSColor.white.withAlphaComponent(0.97).setFill()
roof.fill()
body.fill()
cg.restoreGState()

// Power glyph cut out of the house body.
let cut = NSColor(calibratedRed: 0.04, green: 0.30, blue: 0.38, alpha: 1)
let center = NSPoint(x: 512, y: 452)
let powerArc = NSBezierPath()
powerArc.appendArc(withCenter: center, radius: 76,
                   startAngle: 120, endAngle: 420, clockwise: false)
powerArc.lineWidth = 26
powerArc.lineCapStyle = .round
cut.setStroke()
powerArc.stroke()

let stem = NSBezierPath()
stem.move(to: NSPoint(x: 512, y: 460))
stem.line(to: NSPoint(x: 512, y: 546))
stem.lineWidth = 26
stem.lineCapStyle = .round
stem.stroke()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("cannot encode png\n".utf8))
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: outputPath))
    print("WROTE \(outputPath) \(rep.pixelsWide)x\(rep.pixelsHigh)")
} catch {
    FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
    exit(1)
}
