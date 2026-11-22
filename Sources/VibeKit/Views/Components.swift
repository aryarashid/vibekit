import CoreImage.CIFilterBuiltins
import SwiftUI

/// A live CPU trace. Scaled to at least 10% so an idle server reads as a calm, flat line.
/// In dark mode the line glows, brighter the busier the server is right now.
struct Sparkline: View {
    let values: [Double]
    let tint: Color
    var capacity = 36

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let samples = Array(values.suffix(capacity))
        let current = samples.last ?? 0
        let glow = colorScheme == .dark && current >= 2 ? min(3.5, 1 + current / 20) : 0
        Canvas { context, size in
            let inset: CGFloat = 2
            let width = max(1, size.width - inset * 2)
            let height = max(1, size.height - inset * 2)
            let peak = max(samples.max() ?? 0, 10)
            let step = width / CGFloat(max(capacity - 1, 1))
            let offset = inset + CGFloat(capacity - samples.count) * step
            func point(_ index: Int, _ value: Double) -> CGPoint {
                CGPoint(x: offset + CGFloat(index) * step,
                        y: size.height - inset - CGFloat(min(value / peak, 1)) * height)
            }

            // A faint track across the full width, so a young trace still reads as a meter.
            var track = Path()
            track.move(to: CGPoint(x: inset, y: size.height - inset))
            track.addLine(to: CGPoint(x: samples.count > 1 ? offset : size.width - inset, y: size.height - inset))
            context.stroke(track, with: .color(tint.opacity(0.3)), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1.5, 2.5]))
            guard samples.count > 1 else { return }

            var line = Path()
            for (index, value) in samples.enumerated() {
                let p = point(index, value)
                if index == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }
            var fill = line
            fill.addLine(to: CGPoint(x: point(samples.count - 1, 0).x, y: size.height))
            fill.addLine(to: CGPoint(x: offset, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .linearGradient(Gradient(colors: [tint.opacity(0.28), tint.opacity(0)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            if glow > 0 { context.addFilter(.shadow(color: tint.opacity(0.9), radius: glow)) }
            context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))

            let last = point(samples.count - 1, samples[samples.count - 1])
            context.fill(Path(ellipseIn: CGRect(x: last.x - 2, y: last.y - 2, width: 4, height: 4)), with: .color(tint))
        }
        .accessibilityHidden(true)
    }
}

/// AppKit dims the built-in placeholder again when the menu bar app is inactive.
struct PanelSearchField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        TextField(title, text: $text, prompt: Text(""))
            .textFieldStyle(.plain)
            .overlay(alignment: .leading) {
                if text.isEmpty {
                    Text(title)
                        .foregroundStyle(Theme.readout)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .font(.system(size: 13.5))
    }
}

/// Shared pointer and press feedback for the panel's custom controls.
struct PanelButtonStyle: ButtonStyle {
    var ink: Color = Theme.readout
    var hoverInk: Color = .primary
    var tint: Color = .primary
    var restingFill = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let active = enabled && (hovering || configuration.isPressed)
        configuration.label
            .foregroundStyle(active ? hoverInk : ink)
            .background(Capsule().fill(tint.opacity(configuration.isPressed ? 0.18 : active ? 0.12 : restingFill)))
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// A small square button that only shows a background on hover, like toolbar buttons in menus.
struct IconButton: View {
    let symbol: String
    let help: String
    var role: ButtonRole?
    var size: CGFloat = 26
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .frame(width: size, height: size)
        }
        .buttonStyle(PanelButtonStyle(hoverInk: role == .destructive ? Theme.danger : .primary,
                                     tint: role == .destructive ? Theme.danger : .primary))
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A text button with a quiet pill background, for the detail action bar.
struct PillButton: View {
    let title: String
    var symbol: String?
    var image: NSImage?
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 5) {
                if let image {
                    Image(nsImage: image).resizable().frame(width: 14, height: 14)
                } else if let symbol {
                    Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
                }
                Text(title).font(.system(size: 11.5, weight: .medium))
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .frame(height: 24)
        }
        .buttonStyle(PanelButtonStyle(ink: role == .destructive ? Theme.danger : .primary,
                                     hoverInk: role == .destructive ? Theme.danger : .primary,
                                     tint: role == .destructive ? Theme.danger : .primary, restingFill: 0.06))
    }
}

struct SectionHeader: View {
    let title: String
    let count: Int
    var collapsed: Bool?
    var trailing: AnyView?

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(Theme.sectionFont)
                .kerning(0.7)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Theme.readout)
            if let collapsed {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Theme.readout)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
    }
}

struct QRCodeView: View {
    let text: String

    @State private var code: CGImage?
    private static let context = CIContext()

    var body: some View {
        ZStack {
            if let code {
                // Draw whole modules and leave a four-module quiet zone, including on a 1x display.
                let module = CGFloat(max(1, 112 / code.width))
                Image(code, scale: 1, label: Text("QR code for \(text)"))
                    .interpolation(.none)
                    .resizable()
                    .frame(width: CGFloat(code.width) * module, height: CGFloat(code.height) * module)
                    .padding(module * 4)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white))
            }
        }
        .onChange(of: text, initial: true) { _, url in
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(url.utf8)
            filter.correctionLevel = "M"
            code = filter.outputImage.flatMap { Self.context.createCGImage($0, from: $0.extent) }
        }
    }
}

/// The Vibe Kit mark drawn in SwiftUI.
struct VibeMark: View {
    var live = false
    var size: CGFloat = 30
    var showsDot = true

    var body: some View {
        Canvas { context, canvas in
            let s = canvas.width / 19
            var v = Path()
            v.move(to: CGPoint(x: 2 * s, y: 3.4 * s))
            v.addLine(to: CGPoint(x: 7.4 * s, y: 12.9 * s))
            v.addLine(to: CGPoint(x: 12.8 * s, y: 3.4 * s))
            context.stroke(v, with: .style(.secondary), style: StrokeStyle(lineWidth: 2.2 * s, lineCap: .round, lineJoin: .round))
            guard showsDot else { return }
            let dot = Path(ellipseIn: CGRect(x: 14.2 * s, y: 1.2 * s, width: 4.4 * s, height: 4.4 * s))
            context.fill(dot, with: live ? .color(Theme.live) : .style(.tertiary))
        }
        .frame(width: size, height: size * 16 / 19)
        .accessibilityHidden(true)
    }
}

/// The mark in the panel header. Its dot is a status light for all dev servers together.
struct BrandMark: View {
    let state: LightState
    var size: CGFloat = 18

    var body: some View {
        let s = size / 19
        let diameter = 4.6 * s
        VibeMark(size: size, showsDot: false)
            .overlay(alignment: .topLeading) {
                StatusLight(state: state, diameter: diameter, announcesReady: false).sized()
                    .offset(x: 16.4 * s - diameter / 2, y: 3.4 * s - diameter / 2)
            }
    }
}

/// A switch drawn in the system accent color. The system switch turns gray whenever Vibe Kit is not the active
/// app, which is always: the panel takes the keyboard without activating Vibe Kit. Gray made on and off hard to tell apart.
struct PanelSwitch: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        let track: AnyShapeStyle = if on {
            AnyShapeStyle(Color.accentColor.opacity(isEnabled ? 1 : 0.45))
        } else {
            AnyShapeStyle(Color.primary.opacity(isEnabled ? 0.14 : 0.10))
        }
        Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) { configuration.isOn.toggle() }
        } label: {
            Capsule()
                .fill(track)
                .overlay(Capsule().strokeBorder(Color.primary.opacity(on ? 0 : (isEnabled ? 0.06 : 0.09)), lineWidth: 0.5))
                .frame(width: 30, height: 17)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle()
                        .fill(Color.white.opacity(isEnabled ? 1 : 0.78))
                        .shadow(color: .black.opacity(isEnabled ? 0.22 : 0.14), radius: 0.8, y: 0.5)
                        .frame(width: 13, height: 13)
                        .padding(2)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// One key combination, like ⌘R, drawn as a small key cap.
struct KeyCap: View {
    let keys: String
    init(_ keys: String) { self.keys = keys }

    var body: some View {
        Text(keys)
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: 4.5, style: .continuous).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 4.5, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }
}
