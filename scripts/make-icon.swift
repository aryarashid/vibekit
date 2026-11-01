// Draws the Vibe Kit app icon and writes AppIcon.icns plus a 1024 px PNG.
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
    color(0x111019).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [color(0x1C1930), color(0x0A0910)], atLocations: [0, 1], colorSpace: .sRGB)!
        .draw(in: body, angle: -90)
    // A violet glow behind the mark and a faint warm one at the bottom: the "vibe".
    NSGradient(colors: [color(0x7C5CFF, 0.5), color(0x7C5CFF, 0)])!
        .draw(fromCenter: NSPoint(x: 440, y: 470), radius: 0, toCenter: NSPoint(x: 440, y: 470), radius: 360, options: [])
    NSGradient(colors: [color(0xFF5C8A, 0.18), color(0xFF5C8A, 0)])!
        .draw(fromCenter: NSPoint(x: 800, y: 160), radius: 0, toCenter: NSPoint(x: 800, y: 160), radius: 360, options: [])
    NSGraphicsContext.restoreGraphicsState()

    // Thin top highlight, like light catching the edge of glass.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    let rim = squircle(in: body.insetBy(dx: 2, dy: 2))
    rim.lineWidth = 4
    NSGradient(colors: [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0.0)])!.draw(in: rim, angle: -90)
    color(0xFFFFFF, 0.10).setStroke()
    rim.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // The live dot's glow sits behind the V.
    let dotCenter = NSPoint(x: 772, y: 706)
    NSGradient(colors: [color(0x34D399, 0.45), color(0x34D399, 0)])!
        .draw(fromCenter: dotCenter, radius: 0, toCenter: dotCenter, radius: 150, options: [])

    // The V.
    let v = NSBezierPath()
    v.move(to: NSPoint(x: 252, y: 704))
    v.line(to: NSPoint(x: 438, y: 330))
    v.line(to: NSPoint(x: 624, y: 704))
    v.lineWidth = 96
    v.lineCapStyle = .round
    v.lineJoinStyle = .round
    NSGraphicsContext.saveGraphicsState()
    let vShadow = NSShadow()
    vShadow.shadowColor = color(0x000000, 0.35)
    vShadow.shadowOffset = NSSize(width: 0, height: -8)
    vShadow.shadowBlurRadius = 18
    vShadow.set()
    color(0xF7F5FF).setStroke()
    v.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // The live dot.
    let dot = NSBezierPath(ovalIn: NSRect(x: dotCenter.x - 62, y: dotCenter.y - 62, width: 124, height: 124))
    NSGradient(colors: [color(0x6EF2B4), color(0x22C17F)])!.draw(in: dot, angle: -90)

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

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputDir.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("Wrote \(outputDir.path)/AppIcon.icns and icon.png")
