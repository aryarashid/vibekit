import Testing
@testable import VibeKitCore

@Suite("Contrast")
struct ContrastTests {
    @Test func matchesWCAG() {
        #expect(abs(Contrast.ratio(0x000000, 0xFFFFFF) - 21) < 0.01)
        #expect(abs(Contrast.ratio(0x777777, 0xFFFFFF) - 4.48) < 0.01)
    }

    @Test func everyColorBecomesReadableInBothModes() {
        // A coarse sweep of the sRGB cube, plus the palest and darkest brand colors in use.
        var colors: [UInt32] = [0x8DD6F9, 0x61DAFB, 0x00DC82, 0xFBBF24, 0x059669, 0x000000, 0x1E1B4B]
        for r in stride(from: 0, through: 255, by: 51) {
            for g in stride(from: 0, through: 255, by: 51) {
                for b in stride(from: 0, through: 255, by: 51) {
                    colors.append(UInt32(r << 16 | g << 8 | b))
                }
            }
        }
        for color in colors {
            for dark in [false, true] {
                #expect(Contrast.onPanel(Contrast.readable(color, dark: dark), dark: dark) >= Contrast.minimum,
                        "\(String(color, radix: 16)) dark: \(dark)")
            }
        }
    }

    @Test func leavesReadableColorsAlone() {
        #expect(Contrast.readable(0x7C3AED, dark: false) == 0x7C3AED)
        #expect(Contrast.readable(0x34D399, dark: true) == 0x34D399)
        // Too pale for a light panel: darkened, but only a little past the line.
        let webpack = Contrast.readable(0x8DD6F9, dark: false)
        #expect(webpack != 0x8DD6F9)
        #expect(Contrast.onPanel(webpack, dark: false) < Contrast.minimum + 0.3)
    }
}
