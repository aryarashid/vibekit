// Draws the Vibe Kit app icon and writes AppIcon.icns, a 1024 px icon.png and a 512 px icon-512.png for the README.
// Usage: swift scripts/make-icon.swift <output-dir>
import AppKit

let outputDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build")
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

/// Superellipse close to the macOS icon shape.
func squircle(in rect: NSRect, exponent n: CGFloat = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = pow(abs(c), 2 / n) * a * (c < 0 ? -1 : 1)
        let y = pow(abs(s), 2 / n) * b * (s < 0 ? -1 : 1)
        let point = NSPoint(x: rect.midX + x, y: rect.midY + y)
        if i == 0 { path.move(to: point) } else { path.line(to: point) }
    }
    path.close()
    return path
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Design coordinates run top-down on a 1024 canvas, like the SVG. This flips them for AppKit.
func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: 1024 - y) }

/// The mark: a scope trace that fades in from the left, drops into a V and ends in the live dot.
/// The dot sits level with the tops of the V, as it does in the menu bar glyph.
let tracePoints = [p(96, 342), p(244, 342), p(430, 708), p(616, 342), p(760, 342)]
let dotCenter = p(760, 342)
let dotRadius: CGFloat = 60

func tracePath(width: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: tracePoints[0])
    for point in tracePoints.dropFirst() { path.line(to: point) }
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    return path
}

/// Fills the stroke of `path` with a left-to-right gradient, so the trace fades like phosphor on a scope.
func strokeWithGradient(_ path: NSBezierPath, _ gradient: NSGradient, in ctx: CGContext) {
    ctx.saveGState()
    ctx.addPath(path.cgPath)
    ctx.setLineWidth(path.lineWidth)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    gradient.draw(from: p(110, 0), to: p(640, 0), options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
    ctx.restoreGState()
}

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / 1024, y: size / 1024)

    // Body on the standard macOS grid: 824 pt inside a 1024 canvas.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(in: body)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 24
    shadow.set()
    color(0x0C0A16).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    // Deep instrument glass.
    NSGradient(colors: [color(0x1D1836), color(0x0B0A14), color(0x07060C)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
        .draw(in: body, angle: -90)
    // The scope graticule, too fine to keep at small sizes.
    if size >= 64 {
        let grid = NSBezierPath()
        for k in 1...7 {
            let at = 100 + CGFloat(k) * 103
            grid.move(to: NSPoint(x: at, y: 100)); grid.line(to: NSPoint(x: at, y: 924))
            grid.move(to: NSPoint(x: 100, y: at)); grid.line(to: NSPoint(x: 924, y: at))
        }
        grid.lineWidth = 2
        color(0xFFFFFF, 0.045).setStroke()
        grid.stroke()
    }
    // Violet light pooled under the V, and a faint warm one in the corner: the "vibe".
    let pool = p(430, 610)
    NSGradient(colors: [color(0x7C5CFF, 0.55), color(0x7C5CFF, 0)])!
        .draw(fromCenter: pool, radius: 0, toCenter: pool, radius: 400, options: [])
    let warm = p(860, 900)
    NSGradient(colors: [color(0xFF5C8A, 0.16), color(0xFF5C8A, 0)])!
        .draw(fromCenter: warm, radius: 0, toCenter: warm, radius: 340, options: [])

    // The trace's bloom, then its core. The bloom is a shadow on a layer, so the stroke's clip does not cut it off.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 70 * size / 1024, color: color(0x8B6CFF, 0.9).cgColor)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    strokeWithGradient(tracePath(width: 84),
                       NSGradient(colors: [color(0x7C5CFF, 0), color(0x7C5CFF, 0.8), color(0x9F86FF)],
                                  atLocations: [0, 0.4, 1], colorSpace: .sRGB)!, in: ctx)
    ctx.endTransparencyLayer()
    ctx.restoreGState()
    strokeWithGradient(tracePath(width: 84),
                       NSGradient(colors: [color(0xA48CFF, 0), color(0xB9A6FF, 0.85), color(0xF2EEFF), color(0xFFFFFF)],
                                  atLocations: [0, 0.4, 0.7, 1], colorSpace: .sRGB)!, in: ctx)
    NSGraphicsContext.restoreGraphicsState()

    // Thin top highlight, like light catching the edge of glass.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    let rim = squircle(in: body.insetBy(dx: 2, dy: 2))
    rim.lineWidth = 4
    color(0xFFFFFF, 0.10).setStroke()
    rim.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // The live dot: the trace's head, where "now" is.
    NSGradient(colors: [color(0x34D399, 0.55), color(0x34D399, 0)])!
        .draw(fromCenter: dotCenter, radius: 0, toCenter: dotCenter, radius: 190, options: [])
    let dot = NSBezierPath(ovalIn: NSRect(x: dotCenter.x - dotRadius, y: dotCenter.y - dotRadius,
                                          width: dotRadius * 2, height: dotRadius * 2))
    NSGradient(colors: [color(0x7DF5C0), color(0x1FBF7C)])!.draw(in: dot, angle: -90)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = outputDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let rep = drawIcon(size: CGFloat(base * scale))
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
try drawIcon(size: 1024).representation(using: .png, properties: [:])!.write(to: outputDir.appendingPathComponent("icon.png"))
try drawIcon(size: 512).representation(using: .png, properties: [:])!.write(to: outputDir.appendingPathComponent("icon-512.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputDir.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("Wrote \(outputDir.path)/AppIcon.icns and icon.png")
