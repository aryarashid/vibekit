// Draws the Vibe Kit app icon. Writes AppIcon.icns, a 1024 px icon.png, a 512 px icon-512.png for the README,
// and icon-sheet.png: every size on a dark and a light background, for checking the drawing by eye.
// Usage: swift scripts/make-icon.swift <output-dir>
import AppKit
import SwiftUI // only for the continuous-corner path the system icon shape is built from

let outputDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build")
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

// MARK: - Helpers

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                                           CGFloat(hex & 0xFF) / 255, alpha])!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

func bitmap(width: Int, height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

extension CGContext {
    func saved(_ body: () -> Void) { saveGState(); body(); restoreGState() }
    func layer(_ body: () -> Void) { beginTransparencyLayer(auxiliaryInfo: nil); body(); endTransparencyLayer() }
    func linear(_ stops: [(CGFloat, CGColor)], from a: CGPoint, to b: CGPoint) {
        drawLinearGradient(gradient(stops), start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    func radial(_ stops: [(CGFloat, CGColor)], at center: CGPoint, radius: CGFloat) {
        drawRadialGradient(gradient(stops), startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
                           options: .drawsAfterEndLocation)
    }
    func addCircle(_ center: CGPoint, _ radius: CGFloat) {
        addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }
    /// Keeps what the current layer holds only where `stops` are opaque.
    func mask(_ stops: [(CGFloat, CGColor)], from a: CGPoint, to b: CGPoint) {
        saved { setBlendMode(.destinationIn); linear(stops, from: a, to: b) }
    }
}

// MARK: - Geometry

/// Design coordinates run top-down on a 1024 canvas. The body sits on the macOS icon grid: 824 inside 1024.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)

/// The system icon shape, a continuous-corner rectangle. Radius 215 follows the macOS 26 mask to within a pixel.
/// The outline matters: macOS 26 and later shrink an icon onto a gray plate unless it is a rounded rectangle.
func bodyShape(inset: CGFloat = 0) -> CGPath {
    Path(roundedRect: body.insetBy(dx: inset, dy: inset), cornerRadius: 215 - inset, style: .continuous).cgPath
}

/// The mark, on the proportions of the menu bar glyph in Glyph.swift: a V 10.8 units wide and 9.5 tall,
/// and a dot level with its tops.
struct Mark {
    /// One glyph unit in canvas points.
    var unit: CGFloat
    var stroke: CGFloat
    var dotRadius: CGFloat
    var apex: CGPoint
    /// From the V's right top to the center of the dot.
    var dotGap: CGFloat
    /// Above 64 px the trace runs on into the dot. At 64 px and below the dot stands apart, as it does in the menu bar.
    var joined: Bool

    var baseline: CGFloat { apex.y - 9.5 * unit }
    var left: CGPoint { CGPoint(x: apex.x - 5.4 * unit, y: baseline) }
    var right: CGPoint { CGPoint(x: apex.x + 5.4 * unit, y: baseline) }
    var dot: CGPoint { CGPoint(x: right.x + dotGap, y: baseline) }
    /// One graticule division. The V is three deep and the dot sits three across from the apex,
    /// so the baseline, the apex and the dot all land on lines.
    var division: CGFloat { 9.5 * unit / 3 }

    init(compact: Bool) {
        if compact {
            (unit, stroke, dotRadius, apex, joined) = (33, 88, 72, CGPoint(x: 420, y: 693), false)
            dotGap = stroke / 2 + 40 + dotRadius
        } else {
            (unit, stroke, dotRadius, apex, joined) = (34, 72, 66, CGPoint(x: 432, y: 697), true)
            dotGap = 3 * (9.5 * unit / 3) - 5.4 * unit
        }
    }

    /// The trace: down into the V, up, and (when joined) over a soft elbow into the dot.
    var trace: CGPath {
        let path = CGMutablePath()
        path.move(to: left)
        guard joined else {
            path.addLine(to: apex)
            path.addLine(to: right)
            return path
        }
        path.addArc(tangent1End: apex, tangent2End: right, radius: 12)
        path.addArc(tangent1End: right, tangent2End: dot, radius: 58)
        path.addLine(to: dot)
        return path
    }
}

// MARK: - Drawing

struct IconRenderer {
    let ctx: CGContext
    let pixels: Int
    /// Device pixels per canvas point. Shadows ignore the transform, so every blur and offset is scaled by hand.
    let scale: CGFloat
    /// The 32 and 64 px drawings: a heavier mark, no graticule and less glow.
    let compact: Bool
    let mark: Mark

    /// Draws `body` with a soft glow around it.
    func glow(_ tint: CGColor, blur: CGFloat, _ body: () -> Void) {
        ctx.saved {
            ctx.setShadow(offset: .zero, blur: blur * scale, color: tint)
            ctx.layer(body)
        }
    }

    /// Strokes `path` with blurred edges: the stroke is drawn off the canvas and only its shadow lands on it.
    func softStroke(_ path: CGPath, width: CGFloat, blur: CGFloat, _ tint: CGColor) {
        let away: CGFloat = 4096
        ctx.saved {
            ctx.setShadow(offset: CGSize(width: away * scale, height: 0), blur: blur * scale, color: tint)
            ctx.translateBy(x: -away, y: 0)
            ctx.addPath(path)
            ctx.setLineWidth(width)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(color(0x000000))
            ctx.strokePath()
        }
    }

    func clipToStroke(_ path: CGPath, width: CGFloat) {
        ctx.addPath(path)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
    }

    func draw() {
        // Drop shadow for macOS 14 and 15, matched to the one macOS 26 and later add themselves.
        ctx.saved {
            ctx.setShadow(offset: CGSize(width: 0, height: -8 * scale), blur: 31 * scale, color: color(0x000000, 0.25))
            ctx.addPath(bodyShape())
            ctx.setFillColor(color(0x07060D))
            ctx.fillPath()
        }
        ctx.saved {
            ctx.addPath(bodyShape())
            ctx.clip()
            drawGlass()
            drawTrace()
            drawDot()
            drawRim()
        }
    }

    /// Deep instrument glass, lit from inside by the trace.
    func drawGlass() {
        ctx.linear([(0, color(0x231D49)), (0.5, color(0x120F26)), (1, color(0x07060D))],
                   from: CGPoint(x: 0, y: body.minY), to: CGPoint(x: 0, y: body.maxY))
        // Violet light pooled under the V.
        ctx.radial([(0, color(0x7C5CFF, 0.40)), (0.5, color(0x7C5CFF, 0.13)), (1, color(0x7C5CFF, 0))],
                   at: CGPoint(x: mark.apex.x + 10, y: mark.apex.y - 80), radius: 450)

        // The scope graticule, too fine to keep at small sizes. It is etched in the glass and only shows
        // where the trace lights it, so it fades toward the edges.
        if !compact {
            ctx.saved { ctx.layer {
                ctx.setStrokeColor(color(0xFFFFFF, 0.10))
                ctx.setLineWidth(max(2, 0.55 / scale))
                for step in -8...8 {
                    let x = mark.apex.x + CGFloat(step) * mark.division, y = mark.baseline + CGFloat(step) * mark.division
                    ctx.move(to: CGPoint(x: x, y: body.minY)); ctx.addLine(to: CGPoint(x: x, y: body.maxY))
                    ctx.move(to: CGPoint(x: body.minX, y: y)); ctx.addLine(to: CGPoint(x: body.maxX, y: y))
                }
                ctx.strokePath()
                if pixels >= 256 {
                    // Fine ticks along the two axes that cross at the apex's column and the baseline.
                    for step in -40...40 where step % 5 != 0 {
                        let x = mark.apex.x + CGFloat(step) * mark.division / 5
                        let y = mark.baseline + CGFloat(step) * mark.division / 5
                        ctx.move(to: CGPoint(x: x, y: mark.baseline - 7)); ctx.addLine(to: CGPoint(x: x, y: mark.baseline + 7))
                        ctx.move(to: CGPoint(x: mark.apex.x - 7, y: y)); ctx.addLine(to: CGPoint(x: mark.apex.x + 7, y: y))
                    }
                    ctx.strokePath()
                }
                ctx.setBlendMode(.destinationIn)
                ctx.radial([(0, color(0xFFFFFF)), (0.4, color(0xFFFFFF, 0.72)), (0.75, color(0xFFFFFF, 0.22)), (1, color(0xFFFFFF, 0))],
                           at: CGPoint(x: mark.apex.x + 40, y: mark.apex.y - 140), radius: 430)
            } }
        }
        // Darker toward the corners.
        ctx.radial([(0, color(0x000000, 0)), (0.6, color(0x000000, 0)), (1, color(0x000000, 0.45))],
                   at: CGPoint(x: 512, y: 500), radius: 650)
    }

    /// The trace as lit phosphor: a wide bloom, the beam, and a hotter center. It runs from cool violet where
    /// it started to white where it is now, and picks up the dot's mint as it reaches it.
    func drawTrace() {
        let path = mark.trace, width = mark.stroke
        let start = CGPoint(x: mark.left.x - width / 2, y: 0)
        let end = CGPoint(x: mark.joined ? mark.dot.x : mark.right.x + width / 2, y: 0)
        let beam: [(CGFloat, CGColor)] = mark.joined
            ? [(0, color(0x7D5EFF)), (0.36, color(0xA38CFF)), (0.6, color(0xC9BBFF)), (0.76, color(0xEDE8FF)),
               (0.9, color(0xF3FFF9)), (1, color(0xBDF7DF))]
            : [(0, color(0xA892FF)), (0.5, color(0xD6CBFF)), (1, color(0xFFFFFF))]
        func stroke(_ stops: [(CGFloat, CGColor)]) {
            ctx.saved {
                clipToStroke(path, width: width)
                ctx.linear(stops, from: start, to: end)
            }
        }
        glow(color(0x7C5CFF, 0.8), blur: compact ? 44 : 100) {
            stroke([(0, color(0x6F4DFF)), (0.6, color(0x8B6CFF)), (1, color(0xA58BFF))])
        }
        guard !compact else { return stroke(beam) }
        glow(color(0x9A80FF, 0.7), blur: 24) { stroke(beam) }
        ctx.saved {
            clipToStroke(path, width: width)
            ctx.layer {
                softStroke(path, width: width * 0.34, blur: width * 0.40, color(0xFFFFFF, 1))
                ctx.mask([(0, color(0xFFFFFF, 0.45)), (0.45, color(0xFFFFFF, 0.7)), (0.75, color(0xFFFFFF, 1))], from: start, to: end)
            }
        }
    }

    /// The live dot as a lit LED: its light on the glass, a lens that is brightest in the middle,
    /// a specular fleck, and a bloom that spills over its own edge.
    func drawDot() {
        let center = mark.dot, radius = mark.dotRadius
        ctx.radial([(0, color(0x34D399, 0.62)), (0.3, color(0x34D399, 0.26)), (0.65, color(0x34D399, 0.07)), (1, color(0x34D399, 0))],
                   at: center, radius: radius * (compact ? 2.8 : 3.4))
        ctx.saved {
            ctx.addCircle(center, radius)
            ctx.clip()
            let hot = CGPoint(x: center.x - radius * 0.10, y: center.y - radius * 0.14)
            ctx.drawRadialGradient(gradient([(0, color(0xF4FFFA)), (0.26, color(0xB4FADB)), (0.6, color(0x48E2A8)), (0.9, color(0x20B880)), (1, color(0x169F6C))]),
                                   startCenter: hot, startRadius: 0, endCenter: center, endRadius: radius, options: .drawsAfterEndLocation)
            guard !compact else { return }
            // Light catching the top of the dome, then the fleck.
            ctx.saved {
                ctx.addCircle(center, radius - 5)
                ctx.setLineWidth(4)
                ctx.replacePathWithStrokedPath()
                ctx.clip()
                ctx.linear([(0, color(0xFFFFFF, 0.6)), (0.42, color(0xFFFFFF, 0))],
                           from: CGPoint(x: center.x - radius * 0.3, y: center.y - radius), to: CGPoint(x: center.x + radius * 0.3, y: center.y + radius))
            }
            ctx.translateBy(x: center.x - radius * 0.36, y: center.y - radius * 0.46)
            ctx.rotate(by: -0.62)
            ctx.scaleBy(x: 1, y: 0.5)
            ctx.radial([(0, color(0xFFFFFF, 0.95)), (0.55, color(0xFFFFFF, 0.5)), (1, color(0xFFFFFF, 0))], at: .zero, radius: radius * 0.24)
        }
        guard !compact else { return }
        ctx.saved {
            ctx.setBlendMode(.screen)
            ctx.radial([(0, color(0x8FF5CC, 0.30)), (0.5, color(0x5DE9B4, 0.22)), (1, color(0x34D399, 0))], at: center, radius: radius * 1.9)
        }
    }

    /// Light from above: a soft sheen on the glass and a bright line along its top edge that dims down the sides.
    func drawRim() {
        let top = CGPoint(x: 0, y: body.minY), bottom = CGPoint(x: 0, y: body.maxY)
        ctx.linear([(0, color(0xFFFFFF, 0.065)), (0.3, color(0xFFFFFF, 0.012)), (0.5, color(0xFFFFFF, 0))], from: top, to: bottom)
        if !compact {
            ctx.saved { ctx.layer {
                softStroke(bodyShape(), width: 20, blur: 22, color(0xFFFFFF, 0.11))
                ctx.mask([(0, color(0xFFFFFF)), (0.45, color(0xFFFFFF, 0.3)), (1, color(0xFFFFFF, 0.55))], from: top, to: bottom)
            } }
        }
        let width = max(5, 1.1 / scale)
        ctx.addPath(bodyShape(inset: width / 2))
        ctx.setLineWidth(width)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.linear([(0, color(0xFFFFFF, 0.42)), (0.16, color(0xFFFFFF, 0.16)), (0.6, color(0xFFFFFF, 0.07)), (1, color(0xB7A4FF, 0.20))],
                   from: top, to: bottom)
    }
}

func drawIcon(pixels: Int) -> CGImage {
    let ctx = bitmap(width: pixels, height: pixels)
    // System icons snap the body to whole pixels below 512: 26 px at 32, 52 px at 64. Do the same, or the edge blurs.
    let fit: CGFloat = pixels < 512 ? 832.0 / 824 : 1
    let scale = CGFloat(pixels) / 1024 * fit
    ctx.translateBy(x: CGFloat(pixels) / 2, y: CGFloat(pixels) / 2)
    ctx.scaleBy(x: scale, y: -scale)
    ctx.translateBy(x: -512, y: -512)
    let compact = pixels <= 64
    IconRenderer(ctx: ctx, pixels: pixels, scale: scale, compact: compact, mark: Mark(compact: compact)).draw()
    return ctx.makeImage()!
}

/// What a non-Retina screen shows at 16 pt. There is no image for it, so macOS scales a larger one down.
func scaledDown(to pixels: Int) -> CGImage {
    let ctx = bitmap(width: pixels, height: pixels)
    ctx.interpolationQuality = .high
    ctx.draw(icon(128), in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    return ctx.makeImage()!
}

// MARK: - Output

func write(_ image: CGImage, to url: URL) throws {
    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: url)
}

var rendered: [Int: CGImage] = [:]
func icon(_ pixels: Int) -> CGImage {
    if let image = rendered[pixels] { return image }
    let image = drawIcon(pixels: pixels)
    rendered[pixels] = image
    return image
}

/// The contact sheet: each size as shown, plus the two smallest enlarged pixel for pixel.
func drawSheet() -> CGImage {
    let panel = CGSize(width: 1176, height: 600)
    let ctx = bitmap(width: Int(panel.width), height: Int(panel.height) * 2)
    ctx.translateBy(x: 0, y: panel.height * 2)
    ctx.scaleBy(x: 1, y: -1)
    func place(_ pixels: Int, at origin: CGPoint, side: CGFloat? = nil, label: String, ink: CGColor) {
        let side = side ?? CGFloat(pixels)
        ctx.saved {
            ctx.interpolationQuality = side == CGFloat(pixels) ? .high : .none
            ctx.translateBy(x: origin.x, y: origin.y + side)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(pixels < 32 ? scaledDown(to: pixels) : icon(pixels), in: CGRect(x: 0, y: 0, width: side, height: side))
            let text = NSAttributedString(string: label, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor(cgColor: ink)!])
            ctx.textPosition = CGPoint(x: 0, y: -18)
            CTLineDraw(CTLineCreateWithAttributedString(text), ctx)
        }
    }
    for (row, mood) in [(0x1E1E22, 0xFFFFFF), (0xECECEF, 0x000000)].enumerated() {
        let top = CGFloat(row) * panel.height, ink = color(UInt32(mood.1), 0.55)
        ctx.setFillColor(color(UInt32(mood.0)))
        ctx.fill(CGRect(x: 0, y: top, width: panel.width, height: panel.height))
        place(512, at: CGPoint(x: 32, y: top + 32), label: "512", ink: ink)
        var x: CGFloat = 584
        for pixels in [128, 96, 64, 32, 16] {
            place(pixels, at: CGPoint(x: x, y: top + 32 + 128 - CGFloat(pixels)), label: pixels == 16 ? "16 (scaled by macOS)" : "\(pixels)", ink: ink)
            x += CGFloat(pixels) + 24
        }
        place(256, at: CGPoint(x: 584, y: top + 288), label: "256", ink: ink)
        place(32, at: CGPoint(x: 864, y: top + 416), side: 128, label: "32, enlarged", ink: ink)
        place(16, at: CGPoint(x: 1016, y: top + 416), side: 128, label: "16, enlarged", ink: ink)
    }
    return ctx.makeImage()!
}

let iconset = outputDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
// The 16 and 32 pt images are Retina only. macOS 26 and later put a 1x image of either size on a gray plate when it
// comes from an .icns file, whatever its shape. With those two left out, a non-Retina screen gets a larger image scaled down.
for (base, scale) in [(16, 2), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
    try write(icon(base * scale), to: iconset.appendingPathComponent(name))
}
try write(icon(1024), to: outputDir.appendingPathComponent("icon.png"))
try write(icon(512), to: outputDir.appendingPathComponent("icon-512.png"))
try write(drawSheet(), to: outputDir.appendingPathComponent("icon-sheet.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputDir.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed with status \(iconutil.terminationStatus)\n".utf8))
    exit(1)
}
print("Wrote \(outputDir.path)/AppIcon.icns, icon.png, icon-512.png and icon-sheet.png")
