import AppKit

/// The Vibe Kit mark: a V with a live dot beside it. The dot only shows when something is running.
enum Glyph {
    static func statusImage(live: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 19, height: 16), flipped: true) { _ in
            let v = NSBezierPath()
            v.move(to: NSPoint(x: 2, y: 3.4))
            v.line(to: NSPoint(x: 7.4, y: 12.9))
            v.line(to: NSPoint(x: 12.8, y: 3.4))
            v.lineWidth = 2.2
            v.lineCapStyle = .round
            v.lineJoinStyle = .round
            NSColor.black.setStroke()
            v.stroke()
            if live {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 14.2, y: 1.2, width: 4.4, height: 4.4)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Vibe Kit"
        return image
    }
}
