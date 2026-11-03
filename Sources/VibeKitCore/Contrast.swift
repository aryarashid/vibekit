import Foundation

/// WCAG contrast math, so brand colors used for text stay readable on the panel's glass in both modes.
public enum Contrast {
    /// What body text needs (WCAG AA).
    public static let minimum = 4.5
    /// What shapes and icons need, such as status lights.
    public static let graphics = 3.0
    /// The glass behind the text: about #EBEBEB in light mode and #262626 in dark mode.
    static let lightPanel = luminance(0xEBEBEB)
    static let darkPanel = luminance(0x262626)

    /// Relative luminance of an sRGB color, from 0 (black) to 1 (white).
    public static func luminance(_ hex: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let value = Double((hex >> shift) & 0xFF) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    public static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        ratio(luminances: luminance(a), luminance(b))
    }

    static func ratio(luminances a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Contrast of `hex` against the panel.
    public static func onPanel(_ hex: UInt32, dark: Bool) -> Double {
        ratio(luminances: luminance(hex), dark ? darkPanel : lightPanel)
    }

    /// The color itself when it already reads well on the panel. Otherwise it is mixed toward black in light mode,
    /// or white in dark mode, only as far as it takes to reach `needed`, so the hue stays recognisable.
    public static func readable(_ hex: UInt32, dark: Bool, needed: Double = minimum) -> UInt32 {
        guard onPanel(hex, dark: dark) < needed else { return hex }
        let target: UInt32 = dark ? 0xFFFFFF : 0x000000
        var low = 0.0, high = 1.0
        for _ in 0..<16 {
            let mid = (low + high) / 2
            if onPanel(mix(hex, target, mid), dark: dark) >= needed { high = mid } else { low = mid }
        }
        return mix(hex, target, high)
    }

    /// `a` moved `fraction` of the way to `b`, per sRGB channel.
    static func mix(_ a: UInt32, _ b: UInt32, _ fraction: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let x = Double((a >> shift) & 0xFF), y = Double((b >> shift) & 0xFF)
            return UInt32((x + (y - x) * fraction).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }
}
