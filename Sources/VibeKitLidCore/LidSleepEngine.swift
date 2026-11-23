import Foundation

/// What the lid sleep helper is doing right now. The helper runs as root and writes this where
/// the app can read it, so Settings can show the live state without asking for a password.
public struct LidSleepStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// Not holding the Mac awake: switched off, or the lid sensor cannot be read.
        case off
        /// Lid open. The Mac will stay awake when it closes.
        case armed
        /// Lid open and idle with nothing keeping the Mac awake, so it sleeps as it normally would.
        case idle
        /// Lid closed and counting down to sleep.
        case counting
        /// Lid closed with an external display. No timer runs.
        case docked
        /// On battery at 15% or less, so the Mac sleeps as it normally would.
        case lowBattery
        /// The timer ended and the helper asked the Mac to sleep.
        case slept
        /// The app this helper was installed for is gone, so it does nothing.
        case appMissing
    }

    /// A delay is set and the app is still there.
    public var enabled: Bool
    /// The delay in the config file: 15, 30, 45 or 60, or 0 when off.
    public var minutes: Int
    public var state: State
    /// Seconds left as of `updatedAt`, only while counting.
    public var remainingSeconds: Int?
    /// Unix time of the tick that produced this.
    public var updatedAt: Int64

    public init(enabled: Bool, minutes: Int, state: State, remainingSeconds: Int? = nil, updatedAt: Int64) {
        self.enabled = enabled
        self.minutes = minutes
        self.state = state
        self.remainingSeconds = remainingSeconds
        self.updatedAt = updatedAt
    }

    /// Seconds left at `now`, counting on from when the helper last wrote.
    public func remaining(at now: Int64) -> Int? {
        guard state == .counting, let remainingSeconds else { return nil }
        let elapsed = max(0, min(now - updatedAt, Int64(remainingSeconds)))
        return remainingSeconds - Int(elapsed)
    }

    /// One line of JSON. Written by hand so it cannot fail and the bytes never vary.
    public var encoded: Data {
        var text = "{\"enabled\":\(enabled),\"minutes\":\(minutes)"
        if let remainingSeconds { text += ",\"remainingSeconds\":\(remainingSeconds)" }
        text += ",\"state\":\"\(state.rawValue)\",\"updatedAt\":\(updatedAt)}\n"
        return Data(text.utf8)
    }

    /// nil for anything that is not a status this version could have written.
    public static func decode(_ data: Data) -> LidSleepStatus? {
        guard data.count <= 512, let status = try? JSONDecoder().decode(LidSleepStatus.self, from: data),
              status.minutes == 0 || LidSleepEngine.choices.contains(status.minutes),
              (status.remainingSeconds ?? 0) >= 0, status.updatedAt >= 0 else { return nil }
        return status
    }
}

/// The lid sleep helper's decisions, with no clocks, files or system calls of its own, so every
/// rule can be tested with made-up inputs. The helper feeds it what it read and carries out the
/// actions it asks for.
///
/// The rules, each of which has a test:
/// - Only the delays the app offers count. Anything else is off.
/// - Off, or the app is gone: clear `disablesleep` and forget the timer.
/// - Lid open: hold `disablesleep`, unless the battery is low, or the Mac is idle and would sleep by
///   itself. Then let it, and ask for sleep if it has not gone a minute later.
/// - Lid closed with a display attached: hold `disablesleep`, no timer. Unplugging starts a fresh one.
/// - Lid closed: turn the display off once, count down, then clear `disablesleep` and sleep.
///   Low battery sleeps at once.
/// - After that sleep, a wake with the lid still closed never starts the timer again. If the Mac
///   did not actually sleep, ask again each minute.
/// - A clock set backwards never stretches the delay.
/// - What the system reports for `disablesleep` wins over what the helper last set.
public struct LidSleepEngine: Sendable {
    public static let choices = [15, 30, 45, 60]
    /// At this battery percentage or less, never hold the Mac awake.
    public static let lowBatteryPercent = 15
    public static let maxConfigBytes = 16
    /// How often the helper looks again while a delay is set, in case an event was missed.
    public static let heartbeat = 60
    /// A gap between ticks longer than this means the Mac was asleep in between.
    static let sleepGap: Int64 = 60
    /// How long to wait before asking for sleep again.
    static let retryAfter: Int64 = 60
    /// While waiting to see whether a sleep request took. It has to be well under `sleepGap`,
    /// or an ordinary wait would look like a sleep and the retry would never run.
    static let retryPoll = 20

    public enum Action: Equatable, Sendable {
        case disableSleep(Bool)
        case sleepNow
        case displaySleepNow

        /// The `pmset` arguments. `disablesleep` is set for every power source with `-a`.
        public var arguments: [String] {
            switch self {
            case .disableSleep(let on): return ["disablesleep", on ? "1" : "0"]
            case .sleepNow: return ["sleepnow"]
            case .displaySleepNow: return ["displaysleepnow"]
            }
        }
    }

    /// One reading of the world. `nil` means it could not be read.
    public struct Inputs: Equatable, Sendable {
        /// The delay from the config file, already parsed. 0 when off, missing or not valid.
        public var minutes: Int
        public var appPresent: Bool
        public var lidClosed: Bool?
        /// False while an external display keeps the Mac awake with the lid closed.
        public var clamshellCausesSleep: Bool?
        /// The system's own `SleepDisabled` flag.
        public var sleepDisabled: Bool?
        public var now: Int64?
        public var onBattery: Bool
        public var batteryPercent: Int?
        /// The user has been idle past the sleep timer for the power source in use, and nothing
        /// holds the Mac awake. Only `disablesleep` stops it sleeping by itself.
        public var idleSleepDue: Bool

        public init(minutes: Int, appPresent: Bool = true, lidClosed: Bool?, clamshellCausesSleep: Bool?,
                    sleepDisabled: Bool? = nil, now: Int64?, onBattery: Bool = false, batteryPercent: Int? = nil,
                    idleSleepDue: Bool = false) {
            self.minutes = minutes
            self.appPresent = appPresent
            self.lidClosed = lidClosed
            self.clamshellCausesSleep = clamshellCausesSleep
            self.sleepDisabled = sleepDisabled
            self.now = now
            self.onBattery = onBattery
            self.batteryPercent = batteryPercent
            self.idleSleepDue = idleSleepDue
        }

        var lowBattery: Bool {
            guard onBattery, let batteryPercent else { return false }
            return (0...LidSleepEngine.lowBatteryPercent).contains(batteryPercent)
        }
    }

    /// What the helper remembers between ticks, and across restarts in its state file.
    public struct State: Equatable, Sendable {
        /// When the lid closed and the timer started.
        public var closedAt: Int64?
        /// When sleep was last requested.
        public var firedAt: Int64?
        public var lastTick: Int64?
        /// Sleep was requested for this lid close.
        public var fired = false
        /// The Mac has slept since that request.
        public var slept = false
        public var docked = false
        /// The last `disablesleep` value set or seen.
        public var flag: Bool?
        public var lastMinutes: Int?
        /// When the lid-open Mac was found idle and the flag let go. Kept in memory only.
        public var idleSince: Int64?

        public init() {}

        /// Reads the `key=value` lines the helper writes. Anything not exactly right is skipped,
        /// so a damaged or planted file can only lose the timer, never set something odd.
        public init(serialized text: String) {
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let equals = line.firstIndex(of: "=") else { continue }
                let key = line[..<equals], value = line[line.index(after: equals)...]
                switch key {
                case "closed_at": if let number = Self.number(value) { closedAt = number }
                case "fired_at": if let number = Self.number(value) { firedAt = number }
                case "last_tick": if let number = Self.number(value) { lastTick = number }
                case "fired": if let bit = Self.bit(value) { fired = bit }
                case "slept": if let bit = Self.bit(value) { slept = bit }
                case "docked": if let bit = Self.bit(value) { docked = bit }
                case "flag": if let bit = Self.bit(value) { flag = bit }
                case "last_minutes":
                    if let number = Self.number(value), number == 0 || LidSleepEngine.choices.contains(Int(number)),
                       String(number) == value { lastMinutes = Int(number) }
                default: continue
                }
            }
        }

        public var serialized: String {
            var text = ""
            if let closedAt { text += "closed_at=\(closedAt)\n" }
            if let flag { text += "flag=\(flag ? 1 : 0)\n" }
            if let firedAt { text += "fired_at=\(firedAt)\n" }
            if let lastTick { text += "last_tick=\(lastTick)\n" }
            text += "fired=\(fired ? 1 : 0)\nslept=\(slept ? 1 : 0)\ndocked=\(docked ? 1 : 0)\n"
            text += "last_minutes=\(lastMinutes.map(String.init) ?? "")\n"
            return text
        }

        /// One to twelve plain digits.
        private static func number(_ text: Substring) -> Int64? {
            let digits = text.utf8
            guard (1...12).contains(digits.count), digits.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
            return Int64(text)
        }

        private static func bit(_ text: Substring) -> Bool? {
            text == "1" ? true : text == "0" ? false : nil
        }
    }

    public var state: State

    public init(state: State = State()) {
        self.state = state
    }

    /// The delay in a config file's bytes: 0, 15, 30, 45 or 60 with only blanks around it.
    /// nil for anything else, including a file over 16 bytes. Works on bytes, so a NUL or an
    /// unusual space is refused and not quietly dropped.
    public static func parseMinutes(_ bytes: some Collection<UInt8>) -> Int? {
        guard bytes.count <= maxConfigBytes else { return nil }
        var digits: [UInt8] = []
        var ended = false
        for byte in bytes {
            switch byte {
            case 0x30...0x39:
                // A digit after a blank, as in "4 5", is not a number.
                guard !ended else { return nil }
                digits.append(byte)
            case 0x20, 0x09, 0x0a, 0x0d:
                if !digits.isEmpty { ended = true }
            default:
                return nil
            }
        }
        let text = String(decoding: digits, as: UTF8.self)
        return ([0] + choices).first { String($0) == text }
    }

    /// Assertion types that keep a Mac with an open lid awake, as `IOPMCopyAssertionsStatus` names
    /// them. Apps and tools use these to stay awake, and the system holds one while the display is
    /// on. `PreventSystemSleep` only counts on the power adapter, as it does for macOS.
    static let awakeAssertions = ["PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep", "UserIsActive",
                                  "SystemIsActive", "DisplayWake", "BackgroundTask", "ApplePushServiceTask",
                                  "InteractivePushServiceTask", "InternalPreventSleep", "InternalPreventDisplaySleep",
                                  "NetworkClientActive"]

    /// Whether macOS would put the Mac to sleep now if `disablesleep` were off: the user has been
    /// idle at least as long as the sleep timer for the power source in use, the timer is not
    /// Never, and nothing holds the Mac awake. Anything unknown counts as no.
    public static func idleSleepDue(idleSeconds: Int?, sleepTimerMinutes: Int?, assertions: [String: Int]?,
                                    onBattery: Bool) -> Bool {
        guard let idleSeconds, let sleepTimerMinutes, let assertions, sleepTimerMinutes > 0,
              idleSeconds >= sleepTimerMinutes * 60 else { return false }
        // The system turns this off when something in it must not idle sleep.
        guard assertions["EnableIdleSleep"] != 0 else { return false }
        let names = onBattery ? awakeAssertions : awakeAssertions + ["PreventSystemSleep"]
        return names.allSatisfy { (assertions[$0] ?? 0) == 0 }
    }

    /// The system sleep timer in minutes from `pmset -g custom`, for the battery or the power
    /// adapter. 0 is Never. These are the saved settings, so `disablesleep` cannot hide them. nil if
    /// the output has no such line, so the helper never guesses.
    public static func sleepTimerMinutes(pmsetCustom output: String, onBattery: Bool) -> Int? {
        let header = onBattery ? "Battery Power:" : "AC Power:"
        var inSection = false
        for line in output.split(separator: "\n") {
            // Section headers start at the margin. Settings are indented under them.
            if let first = line.first, first != " " && first != "\t" {
                inSection = line.trimmingCharacters(in: .whitespaces) == header
                continue
            }
            guard inSection else { continue }
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard words.count >= 2, words[0] == "sleep" else { continue }
            guard (1...4).contains(words[1].count), words[1].allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(words[1])
        }
        return nil
    }

    /// Looks at one reading, does what it calls for, and says what state that leaves.
    /// `perform` returns whether the action worked; a sleep that could not be requested is
    /// tried again on the next tick.
    public mutating func tick(_ inputs: Inputs, perform: (Action) -> Bool, log: (String) -> Void = { _ in }) -> LidSleepStatus {
        let configured = Self.choices.contains(inputs.minutes) ? inputs.minutes : 0
        let minutes = inputs.appPresent ? configured : 0
        let stamp = inputs.now.flatMap { $0 >= 0 ? $0 : nil } ?? 0
        func status(_ state: LidSleepStatus.State, remaining: Int? = nil) -> LidSleepStatus {
            LidSleepStatus(enabled: minutes > 0, minutes: configured, state: state, remainingSeconds: remaining, updatedAt: stamp)
        }

        if minutes != state.lastMinutes {
            log("Delay set to \(minutes) minutes")
            state.lastMinutes = minutes
        }
        guard minutes > 0 else {
            state.closedAt = nil
            state.fired = false
            state.docked = false
            setFlag(false, inputs, perform)
            // If Vibe Kit was moved to the Trash, stop keeping the Mac awake rather than outlive it.
            return status(configured > 0 ? .appMissing : .off)
        }
        guard let now = inputs.now, (0...999_999_999_999).contains(now) else {
            setFlag(false, inputs, perform)
            return status(.off)
        }

        // A gap much longer than one poll means the Mac was asleep in between.
        if let last = state.lastTick, now - last > Self.sleepGap || now < last {
            state.slept = true
            // Give a wake its own minute before asking for idle sleep again.
            state.idleSince = nil
        }
        // A clock set backwards must not stretch the delay: move the start back by the same step,
        // so the time already spent with the lid closed still counts.
        if let last = state.lastTick, let closed = state.closedAt, now < last {
            state.closedAt = max(0, closed - (last - now))
        }
        state.lastTick = now

        switch (inputs.lidClosed, inputs.clamshellCausesSleep) {
        case (false?, _):
            state.closedAt = nil
            state.fired = false
            state.docked = false
            // Holding the flag here would stop the Mac going to sleep by itself with the lid
            // open, and run the battery flat. Let it sleep normally, and at once if the lid closes.
            if inputs.lowBattery {
                state.idleSince = nil
                setFlag(false, inputs, perform)
                return status(.lowBattery)
            }
            // The flag has to be on before the lid closes, but while it is on the Mac never sleeps
            // by itself. So when the Mac would sleep now if not for the flag, let go of it. Turning
            // it off may not restart the system's own idle timer, so ask for sleep a minute later.
            if inputs.idleSleepDue {
                setFlag(false, inputs, perform)
                if let since = state.idleSince {
                    if now - since >= Self.retryAfter {
                        if perform(.sleepNow) { log("Requested sleep (idle with the lid open)") }
                        state.idleSince = now
                    }
                } else {
                    state.idleSince = now
                    log("Idle with nothing keeping the Mac awake. Letting it sleep.")
                }
                return status(.idle)
            }
            state.idleSince = nil
            setFlag(true, inputs, perform)
            return status(.armed)
        case (true?, false?):
            state.idleSince = nil
            if !state.docked { log("Lid closed while docked") }
            // Docking is a fresh start: unplugging later starts a new timer.
            state.closedAt = nil
            state.fired = false
            state.docked = true
            setFlag(true, inputs, perform)
            return status(.docked)
        case (true?, true?):
            state.idleSince = nil
        default:
            // Sleep normally if the sensor is unavailable.
            setFlag(false, inputs, perform)
            return status(.off)
        }

        if state.fired {
            // Wakes with the lid still closed never start the timer again. If the Mac never went
            // to sleep after the request, ask again each minute.
            setFlag(false, inputs, perform)
            if !state.slept, now - (state.firedAt ?? 0) >= Self.retryAfter {
                if perform(.sleepNow) { state.firedAt = now }
                log("Requested sleep again")
            }
            return status(.slept)
        }

        state.docked = false
        let closedAt: Int64
        if let closed = state.closedAt {
            closedAt = min(closed, now)
        } else {
            closedAt = now
            log("Lid closed. Timer started.")
            // Only the system stays awake. The lid already darkens the built-in screen; this
            // makes sure of it, and locks the screen if the Mac asks for a password on wake.
            _ = perform(.displaySleepNow)
        }
        state.closedAt = closedAt

        let remaining = Int64(minutes) * 60 - (now - closedAt)
        let reason: String
        if inputs.lowBattery {
            reason = "low battery"
        } else if remaining <= 0 {
            reason = "timer expired"
        } else {
            setFlag(true, inputs, perform)
            return status(.counting, remaining: Int(remaining))
        }
        if setFlag(false, inputs, perform), perform(.sleepNow) {
            state.fired = true
            state.firedAt = now
            state.slept = false
            log("Requested sleep (\(reason))")
            return status(.slept)
        }
        return inputs.lowBattery ? status(.lowBattery) : status(.counting, remaining: 0)
    }

    /// Seconds until the helper should look again with no event to prompt it, or nil when
    /// nothing can change without one. Lid, power and config changes arrive as events; this is
    /// only the countdown itself and a slow safety check.
    public static func secondsUntilNextTick(after status: LidSleepStatus, state: State) -> Int? {
        switch status.state {
        case .off:
            // If clearing `disablesleep` failed, keep retrying until it is confirmed off.
            if state.flag != false { return 10 }
            return status.enabled ? heartbeat : nil
        case .counting:
            // 0 left means the sleep request failed, so try again soon.
            guard let remaining = status.remainingSeconds, remaining > 0 else { return 10 }
            return min(remaining, heartbeat)
        case .slept:
            return state.slept ? heartbeat : retryPoll
        case .idle:
            // Notice the user coming back soon, and keep ticks well under `sleepGap`.
            return retryPoll
        case .lowBattery:
            return state.closedAt == nil ? heartbeat : 10
        case .appMissing:
            return state.flag != false ? 10 : heartbeat
        case .armed, .docked:
            return heartbeat
        }
    }

    @discardableResult
    private mutating func setFlag(_ on: Bool, _ inputs: Inputs, _ perform: (Action) -> Bool) -> Bool {
        // Trust what the system reports over what the helper last set, in case something else changed it.
        if let real = inputs.sleepDisabled { state.flag = real }
        if state.flag == on { return true }
        guard perform(.disableSleep(on)) else { return false }
        state.flag = on
        return true
    }
}
