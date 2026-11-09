import AppKit
import SwiftUI
import VibeKitCore

enum Theme {
    // Brand palette: neon in dark mode, deeper shades in light mode so text stays readable.
    static let mintNS = dynamic(dark: 0x34D399, light: 0x059669)
    static let amberNS = dynamic(dark: 0xFBBF24, light: 0xD97706)
    static let redNS = dynamic(dark: 0xFF5C7A, light: 0xDC2626)
    static let violetNS = dynamic(dark: 0xA78BFA, light: 0x7C3AED)
    static let cyanNS = dynamic(dark: 0x22D3EE, light: 0x0E7490)
    // Status lights are shapes, not text, so they keep more of their color.
    static let mintLightNS = dynamic(dark: 0x34D399, light: 0x059669, needed: Contrast.graphics)
    static let amberLightNS = dynamic(dark: 0xFBBF24, light: 0xD97706, needed: Contrast.graphics)
    static let redLightNS = dynamic(dark: 0xFF5C7A, light: 0xDC2626, needed: Contrast.graphics)

    /// Up and healthy.
    static let live = Color(nsColor: mintNS)
    /// Listening but not answering yet, or running hot.
    static let warning = Color(nsColor: amberNS)
    /// Server errors, crashes and destructive actions.
    static let danger = Color(nsColor: redNS)
    static let violet = Color(nsColor: violetNS)
    static let cyan = Color(nsColor: cyanNS)

    static let rowRadius: CGFloat = 10
    static let portColumn: CGFloat = 64

    static let portFont = Font.system(size: 17, weight: .semibold, design: .monospaced)
    static let titleFont = Font.system(size: 13, weight: .semibold)
    static let metaFont = Font.system(size: 11)
    static let monoSmall = Font.system(size: 10.5, design: .monospaced)
    static let sectionFont = Font.system(size: 10.5, weight: .semibold)

    /// CPU above this counts as busy: compiling, reloading or serving load.
    static let busyCPU = 10.0

    /// Color for a CPU reading: none while calm, amber when warm, red when it is eating cores.
    static func heat(_ cpu: Double) -> Color? {
        if cpu >= 80 { return danger }
        if cpu >= 30 { return warning }
        return nil
    }

    /// A color for each appearance, each nudged until it reads as text (or, with `needed`, as a shape) on the panel's glass.
    static func dynamic(dark: UInt32, light: UInt32, needed: Double = Contrast.minimum) -> NSColor {
        let dark = srgb(Contrast.readable(dark, dark: true, needed: needed))
        let light = srgb(Contrast.readable(light, dark: false, needed: needed))
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static func srgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// Brand colors, darker in light mode and lighter in dark mode only when they would be hard to read.
    @MainActor static func tint(_ hex: UInt32?) -> Color {
        guard let hex else { return .primary }
        if let cached = tints[hex] { return cached }
        let color = Color(nsColor: dynamic(dark: hex, light: hex))
        tints[hex] = color
        return color
    }

    @MainActor private static var tints: [UInt32: Color] = [:]
}

extension Framework {
    @MainActor var tint: Color { Theme.tint(color) }
}

enum Format {
    static func uptime(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        let days = hours / 24
        return hours % 24 == 0 ? "\(days)d" : "\(days)d \(hours % 24)h"
    }

    static func memory(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb < 1 { return "<1 MB" }
        if mb < 1024 { return "\(Int(mb.rounded())) MB" }
        return String(format: "%.1f GB", mb / 1024)
    }

    static func cpu(_ value: Double) -> String {
        if value < 0.05 { return "0%" }
        if value < 10 { return String(format: "%.1f%%", value) }
        return "\(Int(value.rounded()))%"
    }

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        return uptime(since: date, now: now) + " ago"
    }

    /// "now", "5m", "3h", "2d", "6w": for tight columns.
    static func short(since date: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date))) / 60
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        return days < 14 ? "\(days)d" : "\(days / 7)w"
    }

    /// A rough token count, at about four characters a token, which is close for English prose and code.
    static func tokens(_ text: String) -> String {
        let count = Int((Double(text.count) / 4).rounded())
        return count == 1 ? "about 1 token" : "about \(count.formatted()) tokens"
    }

    static func path(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
