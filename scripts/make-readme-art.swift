// Composes the README images from transparent panel snapshots: the panel on a glass effect over a wallpaper,
// hanging from a menu bar. Run through scripts/screenshots.sh, which renders the snapshots first.
// Usage: swift scripts/make-readme-art.swift <snapshots-dir> <output-dir>
import AppKit
import CoreImage

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let scale: CGFloat = 2

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func snapshot(_ name: String) -> CGImage {
    let url = input.appendingPathComponent(name)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("Missing \(url.path)") }
    return image
}

enum Mood { case dark, light }

struct Placed {
    let image: CGImage
    /// Top-left corner in points.
    let origin: CGPoint
    let mood: Mood
}

/// A drawing context in points with a top-left origin, backed by a 2x bitmap.
final class Canvas {
    let size: CGSize
    let context: CGContext

    init(size: CGSize) {
        self.size = size
        context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
    }

    var image: CGImage { context.makeImage()! }

    /// Draws a bitmap upright at a rect given in top-left coordinates.
    func draw(_ image: CGImage, in rect: CGRect) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    func glow(_ hex: UInt32, alpha: CGFloat, at center: CGPoint, radius: CGFloat) {
        let gradient = CGGradient(colorsSpace: nil, colors: [color(hex, alpha), color(hex, 0)] as CFArray, locations: [0, 1])!
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    func text(_ string: String, at point: CGPoint, font: NSFont, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]).draw(at: point)
        NSGraphicsContext.restoreGraphicsState()
    }

    func symbol(_ name: String, at rect: CGRect, color: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: rect.height, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let size = image.size
        image.draw(in: CGRect(x: rect.minX, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}

func wallpaper(_ size: CGSize, _ mood: Mood) -> CGImage {
    let canvas = Canvas(size: size)
    let ctx = canvas.context
    let w = size.width, h = size.height
    switch mood {
    case .dark:
        let base = CGGradient(colorsSpace: nil, colors: [color(0x16132B), color(0x07060D)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(base, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        canvas.glow(0x7C5CFF, alpha: 0.55, at: CGPoint(x: w * 0.18, y: h * 0.3), radius: w * 0.45)
        canvas.glow(0xFF5C8A, alpha: 0.32, at: CGPoint(x: w * 0.3, y: h * 0.95), radius: w * 0.42)
        canvas.glow(0x34D399, alpha: 0.22, at: CGPoint(x: w * 0.92, y: h * 0.85), radius: w * 0.35)
    case .light:
        let base = CGGradient(colorsSpace: nil, colors: [color(0xF3F1FF), color(0xE6E9F5)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(base, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        canvas.glow(0x8B7CFF, alpha: 0.45, at: CGPoint(x: w * 0.18, y: h * 0.3), radius: w * 0.45)
        canvas.glow(0xFF8FB0, alpha: 0.38, at: CGPoint(x: w * 0.32, y: h * 0.95), radius: w * 0.42)
        canvas.glow(0x6EE7B7, alpha: 0.35, at: CGPoint(x: w * 0.92, y: h * 0.85), radius: w * 0.35)
    }
    return canvas.image
}

func blurred(_ image: CGImage, radius: CGFloat) -> CGImage {
    let ci = CIImage(cgImage: image).clampedToExtent()
    let blur = ci.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius * scale])
    return CIContext().createCGImage(blur, from: CIImage(cgImage: image).extent)!
}

/// The status item glyph: a V with a live dot, the same shape as the app's menu bar icon.
func drawGlyph(_ canvas: Canvas, at origin: CGPoint, color tint: CGColor) {
    let ctx = canvas.context
    ctx.saveGState()
    ctx.translateBy(x: origin.x, y: origin.y)
    ctx.setStrokeColor(tint)
    ctx.setLineWidth(2.2)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 2, y: 3.4))
    ctx.addLine(to: CGPoint(x: 7.4, y: 12.9))
    ctx.addLine(to: CGPoint(x: 12.8, y: 3.4))
    ctx.strokePath()
    ctx.setFillColor(tint)
    ctx.fillEllipse(in: CGRect(x: 14.2, y: 1.2, width: 4.4, height: 4.4))
    ctx.restoreGState()
}

/// Draws a menu bar and returns the horizontal center of the Vibe Kit item.
func drawMenuBar(_ canvas: Canvas, background: CGImage, mood: Mood, count: Int) -> CGFloat {
    let height: CGFloat = 30
    let bar = CGRect(x: 0, y: 0, width: canvas.size.width, height: height)
    let ctx = canvas.context
    ctx.saveGState()
    ctx.clip(to: bar)
    canvas.draw(blurred(background, radius: 20), in: CGRect(origin: .zero, size: canvas.size))
    ctx.setFillColor(mood == .dark ? color(0x000000, 0.28) : color(0xFFFFFF, 0.45))
    ctx.fill(bar)
    ctx.restoreGState()

    let ink: NSColor = mood == .dark ? .white : .black
    let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    var x = canvas.size.width - 16
    let clock = "Sat Oct 31  9:41 AM"
    let clockWidth = NSAttributedString(string: clock, attributes: [.font: font]).size().width
    x -= clockWidth
    canvas.text(clock, at: CGPoint(x: x, y: 6.5), font: font, color: ink)
    for name in ["switch.2", "wifi", "battery.75percent"] {
        x -= 30
        canvas.symbol(name, at: CGRect(x: x, y: 8, width: 22, height: 14), color: ink)
    }
    // The Vibe Kit item: glyph and count, with the highlight it gets while its panel is open.
    let countText = "\(count)"
    let countFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
    let itemWidth: CGFloat = 19 + 3 + NSAttributedString(string: countText, attributes: [.font: countFont]).size().width + 14
    x -= itemWidth + 10
    let item = CGRect(x: x, y: 4, width: itemWidth, height: 22)
    ctx.setFillColor(mood == .dark ? color(0xFFFFFF, 0.18) : color(0x000000, 0.1))
    ctx.addPath(CGPath(roundedRect: item, cornerWidth: 6, cornerHeight: 6, transform: nil))
    ctx.fillPath()
    drawGlyph(canvas, at: CGPoint(x: item.minX + 7, y: 7), color: ink.cgColor)
    canvas.text(countText, at: CGPoint(x: item.minX + 7 + 19 + 3, y: 7), font: countFont, color: ink)
    return item.midX
}

/// A panel on Liquid Glass: blurred wallpaper, a tint, a light rim and a soft shadow, then the content.
func drawPanel(_ canvas: Canvas, _ panel: Placed, background: CGImage) {
    let size = CGSize(width: CGFloat(panel.image.width) / scale, height: CGFloat(panel.image.height) / scale)
    let rect = CGRect(origin: panel.origin, size: size)
    let shape = CGPath(roundedRect: rect, cornerWidth: 16, cornerHeight: 16, transform: nil)
    let ctx = canvas.context

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 44, color: color(0x000000, panel.mood == .dark ? 0.5 : 0.22))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x000000, 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    canvas.draw(blurred(background, radius: 28), in: CGRect(origin: .zero, size: canvas.size))
    ctx.setFillColor(panel.mood == .dark ? color(0x1A1922, 0.72) : color(0xF7F7FA, 0.74))
    ctx.fill(rect)
    canvas.draw(panel.image, in: rect)
    ctx.restoreGState()

    ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 15.5, cornerHeight: 15.5, transform: nil))
    ctx.setStrokeColor(panel.mood == .dark ? color(0xFFFFFF, 0.16) : color(0x000000, 0.1))
    ctx.setLineWidth(1)
    ctx.strokePath()
}

func save(_ image: CGImage, _ name: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    try! rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    print("Wrote \(output.appendingPathComponent(name).path)")
}

/// The hero: one panel hanging from the menu bar.
func hero(_ mood: Mood, panel name: String, file: String) {
    let image = snapshot(name)
    let size = CGSize(width: 700, height: 30 + 6 + CGFloat(image.height) / scale + 56)
    let canvas = Canvas(size: size)
    let background = wallpaper(size, mood)
    canvas.draw(background, in: CGRect(origin: .zero, size: size))
    let itemX = drawMenuBar(canvas, background: background, mood: mood, count: 5)
    let width = CGFloat(image.width) / scale
    let x = min(itemX - width / 2, size.width - width - 16)
    drawPanel(canvas, Placed(image: image, origin: CGPoint(x: x, y: 36), mood: mood), background: background)
    save(canvas.image, file)
}

/// Two panels side by side, without a menu bar, for the feature tour.
func pair(_ left: (String, Mood), _ right: (String, Mood), file: String, mood: Mood) {
    let a = snapshot(left.0), b = snapshot(right.0)
    let wa = CGFloat(a.width) / scale, wb = CGFloat(b.width) / scale
    let ha = CGFloat(a.height) / scale, hb = CGFloat(b.height) / scale
    let gap: CGFloat = 40, margin: CGFloat = 48
    let size = CGSize(width: margin * 2 + wa + gap + wb, height: margin * 2 + max(ha, hb))
    let canvas = Canvas(size: size)
    let background = wallpaper(size, mood)
    canvas.draw(background, in: CGRect(origin: .zero, size: size))
    drawPanel(canvas, Placed(image: a, origin: CGPoint(x: margin, y: margin), mood: left.1), background: background)
    drawPanel(canvas, Placed(image: b, origin: CGPoint(x: margin + wa + gap, y: margin), mood: right.1), background: background)
    save(canvas.image, file)
}

hero(.dark, panel: "list-dark.png", file: "hero-dark.png")
hero(.light, panel: "list-light.png", file: "hero-light.png")
pair(("details-dark.png", .dark), ("settings-dark.png", .dark), file: "details-dark.png", mood: .dark)
pair(("details-light.png", .light), ("settings-light.png", .light), file: "details-light.png", mood: .light)
pair(("prompts-dark.png", .dark), ("editor-dark.png", .dark), file: "prompts-dark.png", mood: .dark)
pair(("prompts-light.png", .light), ("editor-light.png", .light), file: "prompts-light.png", mood: .light)
