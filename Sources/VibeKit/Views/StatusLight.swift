import AppKit
import SwiftUI
import VibeKitCore

/// What a status light says. Each look carries one fact, so the column of lights reads like a rack of meters.
enum LightState: Equatable {
    /// Up and answering. Steady mint.
    case up
    /// Up and using CPU right now, such as compiling or reloading. Mint with a ripple.
    case busy
    /// Listening, but has not answered its first request yet. Amber, breathing.
    case waiting
    /// Listening, but does not answer HTTP. Steady amber.
    case silent
    /// Answering with server errors (5xx). Steady red.
    case failing
    /// Not a dev server: an app or system listener. Dim grey, no glow.
    case neutral
    /// Stopped. Hollow grey ring.
    case stopped
    /// Exited with an error. Hollow red ring.
    case crashed

    var isUp: Bool { self == .up || self == .busy }
}

extension ServerStore {
    /// The light for a server: what the row's status dot shows.
    func light(for server: Server) -> LightState {
        let busy = server.cpu >= Theme.busyCPU
        switch server.category {
        case .other:
            return .neutral
        case .database, .service:
            return busy ? .busy : .up
        case .dev:
            guard server.framework.speaksHTTP else { return busy ? .busy : .up }
            if unanswered.contains(server.id) { return .silent }
            guard let page = pages[server.id] else { return .waiting }
            if page.status >= 500 { return .failing }
            return busy ? .busy : .up
        }
    }

    /// One light for all dev servers, worst first: failing, then not answering, then up.
    var overallLight: LightState {
        let lights = devServers.map(light(for:))
        if lights.isEmpty { return .stopped }
        if lights.contains(.failing) { return .failing }
        if lights.contains(where: { $0 == .waiting || $0 == .silent }) { return .waiting }
        return .up
    }
}

/// A status dot drawn with Core Animation. The ripple, breathing and ready flash are layer animations,
/// which the window server runs on its own, so Vibe Kit does no work per frame while they play.
struct StatusLight: NSViewRepresentable {
    let state: LightState
    var diameter: CGFloat = 7
    /// Flash a ring when the light turns from amber to up, because the server just became ready.
    var announcesReady = true

    /// The view is larger than the dot so the ripple has room; negative padding keeps the layout size.
    static let canvas: CGFloat = 22

    func makeNSView(context: Context) -> StatusLightView {
        StatusLightView(diameter: diameter)
    }

    func updateNSView(_ view: StatusLightView, context: Context) {
        view.announcesReady = announcesReady
        view.apply(state)
    }
}

extension StatusLight {
    /// A status light that takes up only `diameter` points in layout.
    func sized() -> some View {
        frame(width: Self.canvas, height: Self.canvas)
            .padding(-(Self.canvas - diameter) / 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

final class StatusLightView: NSView {
    private let dot = CALayer()
    private let ring = CALayer()
    private let diameter: CGFloat
    private var state: LightState?
    var announcesReady = true

    init(diameter: CGFloat) {
        self.diameter = diameter
        super.init(frame: NSRect(x: 0, y: 0, width: StatusLight.canvas, height: StatusLight.canvas))
        wantsLayer = true
        layer?.masksToBounds = false
        for sub in [ring, dot] {
            sub.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            sub.cornerRadius = diameter / 2
            layer?.addSublayer(sub)
        }
        ring.opacity = 0
        dot.shadowOffset = .zero
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.position = center
        ring.position = center
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let state { render(state, from: state) }
    }

    func apply(_ next: LightState) {
        guard next != state else { return }
        let previous = state
        state = next
        render(next, from: previous)
    }

    @objc private func accessibilityOptionsChanged() {
        if let state { render(state, from: state) }
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    private func color(for state: LightState) -> NSColor {
        switch state {
        case .up, .busy: Theme.mintLightNS
        case .waiting, .silent: Theme.amberLightNS
        case .failing, .crashed: Theme.redLightNS
        case .neutral, .stopped: NSColor.secondaryLabelColor
        }
    }

    private func cgColor(_ color: NSColor, alpha: CGFloat = 1) -> CGColor {
        var result = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            result = color.withAlphaComponent(alpha).cgColor
        }
        return result
    }

    private func render(_ state: LightState, from previous: LightState?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let tint = color(for: state)
        let hollow = state == .stopped || state == .crashed
        dot.backgroundColor = hollow ? NSColor.clear.cgColor : cgColor(tint, alpha: state == .neutral ? 0.5 : 1)
        dot.borderWidth = hollow ? 1 : 0
        dot.borderColor = cgColor(tint, alpha: state == .stopped ? 0.6 : 0.9)
        // A soft glow in dark mode, where neon reads as light. None for neutral and stopped.
        let glows = isDark && !hollow && state != .neutral
        dot.shadowColor = cgColor(tint)
        dot.shadowRadius = 3
        dot.shadowOpacity = glows ? 0.85 : 0
        ring.borderWidth = 1.2
        ring.borderColor = cgColor(tint)
        ring.backgroundColor = cgColor(tint, alpha: 0.12)
        CATransaction.commit()

        dot.removeAnimation(forKey: "breathe")
        ring.removeAnimation(forKey: "ripple")
        ring.removeAnimation(forKey: "ready")
        guard !reduceMotion else { return }

        switch state {
        case .busy:
            ring.add(ripple(scale: 2.6, duration: 1.5, repeats: true), forKey: "ripple")
        case .waiting:
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 1
            breathe.toValue = 0.3
            breathe.duration = 0.9
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(breathe, forKey: "breathe")
        default:
            break
        }

        // Just became ready: one ring, so you know to reload the browser.
        if announcesReady, state.isUp, let previous, previous == .waiting || previous == .silent {
            ring.add(ripple(scale: 3.4, duration: 0.9, repeats: false), forKey: "ready")
        }
    }

    private func ripple(scale: CGFloat, duration: CFTimeInterval, repeats: Bool) -> CAAnimation {
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = scale
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.75
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.repeatCount = repeats ? .infinity : 1
        group.isRemovedOnCompletion = true
        return group
    }
}
