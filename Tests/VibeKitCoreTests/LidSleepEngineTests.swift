import VibeKitCore
import XCTest

/// The lid sleep rules with made-up readings and no helper process, for the cases a fake folder
/// cannot reach: actions that fail, and how often the daemon should look again.
final class LidSleepEngineTests: XCTestCase {
    private var engine = LidSleepEngine()
    private var actions: [LidSleepEngine.Action] = []
    private var failing: Set<String> = []
    private var log: [String] = []

    @discardableResult
    private func tick(minutes: Int = 45, lid: Bool? = false, causes: Bool? = true, flag: Bool? = nil, now: Int64? = 1000,
                      battery: Int? = nil, appPresent: Bool = true) -> LidSleepStatus {
        let inputs = LidSleepEngine.Inputs(
            minutes: minutes, appPresent: appPresent, lidClosed: lid, clamshellCausesSleep: causes, sleepDisabled: flag,
            now: now, onBattery: battery != nil, batteryPercent: battery)
        return engine.tick(inputs, perform: { action in
            actions.append(action)
            return !failing.contains(action.arguments[0])
        }, log: { log.append($0) })
    }

    func testConfigBytesAreReadStrictly() {
        func parse(_ text: String) -> Int? { LidSleepEngine.parseMinutes(Array(text.utf8)) }
        XCTAssertEqual(parse("45"), 45)
        XCTAssertEqual(parse("  30\n"), 30)
        XCTAssertEqual(parse("\t15\r\n"), 15)
        XCTAssertEqual(parse("60 "), 60)
        XCTAssertEqual(parse("0\n"), 0)
        XCTAssertEqual(parse("45" + String(repeating: " ", count: 14)), 45)
        for bad in ["", " ", "20", "045", "4 5", "45 0", "450", "abc", "45x", "-45", "+45", "45.0", "4\u{0}5", "45\u{0}",
                    "\u{a0}45", "\u{2003}45", "４５", "45\u{b}", "45; rm -rf /", "$(touch x)",
                    "45" + String(repeating: " ", count: 15)] {
            XCTAssertNil(parse(bad), bad.debugDescription)
        }
    }

    func testStateSurvivesBeingWrittenAndReadBack() {
        var state = LidSleepEngine.State()
        XCTAssertEqual(state.serialized, "fired=0\nslept=0\ndocked=0\nlast_minutes=\n")
        XCTAssertEqual(LidSleepEngine.State(serialized: state.serialized), state)
        state.closedAt = 1_700_000_000
        state.firedAt = 1_700_002_700
        state.lastTick = 1_700_002_710
        state.fired = true
        state.slept = true
        state.docked = true
        state.flag = false
        state.lastMinutes = 45
        XCTAssertEqual(state.serialized, "closed_at=1700000000\nflag=0\nfired_at=1700002700\nlast_tick=1700002710\nfired=1\nslept=1\ndocked=1\nlast_minutes=45\n")
        XCTAssertEqual(LidSleepEngine.State(serialized: state.serialized), state)
        // The file the shell helper wrote reads the same, so a countdown survives the upgrade.
        XCTAssertEqual(LidSleepEngine.State(serialized: "closed_at=1000\nflag=1\nlast_tick=1010\nfired=0\nslept=0\ndocked=0\nlast_minutes=45").closedAt, 1000)
    }

    func testDamagedStateSetsNothing() {
        let bad = ["closed_at=$(touch pwned)", "closed_at=-5", "closed_at=1234567890123", "closed_at=", "closed_at=1 ",
                   "fired=1x", "fired=2", "flag=10", "slept=yes", "docked=", "last_minutes=20", "last_minutes=045",
                   "fired = 1", "FIRED=1", "nonsense", "=1", "closed_at=١٢٣", "fired=1\r"]
        XCTAssertEqual(LidSleepEngine.State(serialized: bad.joined(separator: "\n")), LidSleepEngine.State())
    }

    func testASleepRequestThatFailsIsTriedAgain() {
        tick()
        tick(lid: true)
        failing = ["sleepnow"]
        var status = tick(lid: true, now: 1000 + 45 * 60)
        // Not marked as asleep, so the next look asks again rather than waiting a minute.
        XCTAssertFalse(engine.state.fired)
        XCTAssertEqual(status.state, .counting)
        XCTAssertEqual(status.remainingSeconds, 0)
        XCTAssertEqual(LidSleepEngine.secondsUntilNextTick(after: status, state: engine.state), 10)
        failing = []
        status = tick(lid: true, now: 1010 + 45 * 60)
        XCTAssertTrue(engine.state.fired)
        XCTAssertEqual(status.state, .slept)
        XCTAssertEqual(actions.filter { $0 == .sleepNow }.count, 2)
        XCTAssertEqual(log.last, "Requested sleep (timer expired)")
    }

    func testSleepIsNotRequestedWhileTheFlagCannotBeCleared() {
        tick()
        tick(lid: true)
        failing = ["disablesleep"]
        let status = tick(lid: true, now: 1000 + 45 * 60)
        // `sleepnow` with the flag still set would not sleep the Mac, so it is not sent yet.
        XCTAssertFalse(actions.contains(.sleepNow))
        XCTAssertFalse(engine.state.fired)
        XCTAssertEqual(engine.state.flag, true)
        XCTAssertEqual(status.state, .counting)
    }

    func testLowBatteryWithTheLidOpenLetsTheMacSleep() {
        XCTAssertEqual(tick(battery: 16).state, .armed)
        XCTAssertEqual(tick(battery: 15).state, .lowBattery)
        XCTAssertEqual(tick(battery: 0).state, .lowBattery)
        XCTAssertEqual(actions, [.disableSleep(true), .disableSleep(false)])
        // Docked is left as it was: a display keeps the Mac awake, and no timer runs.
        XCTAssertEqual(tick(lid: true, causes: false, battery: 5).state, .docked)
        XCTAssertEqual(actions.last, .disableSleep(true))
    }

    func testAnUnreadableClockOrSensorHoldsNothing() {
        tick()
        XCTAssertEqual(tick(now: nil).state, .off)
        XCTAssertEqual(actions, [.disableSleep(true), .disableSleep(false)])
        tick()
        XCTAssertEqual(tick(lid: nil).state, .off)
        XCTAssertEqual(tick(lid: true, causes: nil).state, .off)
        XCTAssertEqual(tick(now: -1).state, .off)
        XCTAssertEqual(tick(now: 1_000_000_000_000).state, .off)
        XCTAssertEqual(actions.last, .disableSleep(false))
    }

    func testOnlyTheOfferedDelaysCount() {
        for minutes in [-45, 1, 20, 61, 4500, Int.max, Int.min] {
            XCTAssertEqual(tick(minutes: minutes).state, .off, "\(minutes)")
            XCTAssertFalse(actions.contains(.disableSleep(true)), "\(minutes)")
        }
    }

    func testTheDaemonLooksAgainOnlyAsOftenAsItMust() {
        func next(_ status: LidSleepStatus) -> Int? { LidSleepEngine.secondsUntilNextTick(after: status, state: engine.state) }
        // Off: nothing can change without an event, so no timer at all.
        XCTAssertNil(next(tick(minutes: 0)))
        // A delay is set: a slow heartbeat, never the old 10 second poll.
        XCTAssertEqual(next(tick()), 60)
        XCTAssertEqual(next(tick(lid: true, causes: false)), 60)
        XCTAssertEqual(next(tick(appPresent: false)), 60)
        XCTAssertEqual(next(tick(battery: 10)), 60)
        // Counting: the heartbeat, then exactly the time that is left.
        XCTAssertEqual(next(tick(lid: true)), 60)
        XCTAssertEqual(next(tick(lid: true, now: 1000 + 45 * 60 - 7)), 7)
        // Sleep requested: look well inside a minute, so an ordinary wait is not taken for a sleep.
        let fired = tick(lid: true, now: 1000 + 45 * 60)
        XCTAssertEqual(fired.state, .slept)
        XCTAssertEqual(next(fired), 20)
        // It did sleep and woke with the lid closed: back to the slow heartbeat.
        XCTAssertEqual(next(tick(lid: true, now: 9000)), 60)
        XCTAssertTrue(engine.state.slept)
    }

    func testTheRetryStillRunsAtTheDaemonsOwnPace() {
        // The Mac ignores the first request. Looking every 20 seconds, the helper must never
        // mistake its own waiting for a sleep, and must ask again after a minute.
        tick()
        tick(lid: true)
        var now: Int64 = 1000 + 45 * 60
        var status = tick(lid: true, now: now)
        for _ in 0..<6 {
            now += Int64(LidSleepEngine.secondsUntilNextTick(after: status, state: engine.state) ?? 0)
            status = tick(lid: true, now: now)
        }
        XCTAssertFalse(engine.state.slept)
        XCTAssertEqual(actions.filter { $0 == .sleepNow }.count, 3)
    }

    func testStatusReadsBackAndRefusesNonsense() throws {
        let status = LidSleepStatus(enabled: true, minutes: 45, state: .counting, remainingSeconds: 90, updatedAt: 1000)
        XCTAssertEqual(String(decoding: status.encoded, as: UTF8.self),
                       #"{"enabled":true,"minutes":45,"remainingSeconds":90,"state":"counting","updatedAt":1000}"# + "\n")
        XCTAssertEqual(LidSleepStatus.decode(status.encoded), status)
        for state in [LidSleepStatus.State.off, .armed, .counting, .docked, .lowBattery, .slept, .appMissing] {
            let other = LidSleepStatus(enabled: false, minutes: 0, state: state, updatedAt: 5)
            XCTAssertEqual(LidSleepStatus.decode(other.encoded), other)
        }
        for bad in ["", "{}", "not json", #"{"enabled":true,"minutes":20,"state":"armed","updatedAt":1}"#,
                    #"{"enabled":true,"minutes":45,"state":"dancing","updatedAt":1}"#,
                    #"{"enabled":true,"minutes":45,"state":"counting","remainingSeconds":-1,"updatedAt":1}"#,
                    #"{"enabled":true,"minutes":45,"state":"armed","updatedAt":-1}"#,
                    #"{"enabled":true,"minutes":45,"state":"armed","updatedAt":1}"# + String(repeating: " ", count: 600)] {
            XCTAssertNil(LidSleepStatus.decode(Data(bad.utf8)), bad)
        }
        XCTAssertNil(LidSleepStatus(enabled: true, minutes: 45, state: .armed, updatedAt: 1).remaining(at: 5))
        XCTAssertEqual(status.remaining(at: 900), 90, "A clock behind the helper's does not add time")
    }
}
