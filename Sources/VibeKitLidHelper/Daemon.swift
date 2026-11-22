import Darwin
import Dispatch
import IOKit
import IOKit.ps
import VibeKitLidCore
import notify

/// The long-running helper. It sleeps until something changes and then takes one fresh reading:
///
/// - the lid, or a display that keeps the Mac awake with the lid closed (IOKit, at once)
/// - the delay in the config file (a file watch, at once)
/// - the power source or battery level (a system notification)
/// - the countdown reaching its end (a timer, only while counting)
///
/// A slow heartbeat runs while a delay is set, so a missed event costs a minute, never safety.
/// With the delay off, nothing runs at all.
///
/// Everything here happens on one queue, which is what makes the class safe to share.
final class Daemon: @unchecked Sendable {
    private let system: HelperSystem
    private let queue = DispatchQueue(label: "dev.vibekit.lid-sleep")
    private var engine = LidSleepEngine()
    private var savedState = ""
    private var lastStatus: LidSleepStatus?

    private var signals: [DispatchSourceSignal] = []
    /// Two timers for one wait. The uptime one is not thrown by a clock change; the wall-clock
    /// one fires as soon as the Mac wakes if the time passed while it slept.
    private let uptimeTimer: DispatchSourceTimer
    private let wallTimer: DispatchSourceTimer
    private var lidEvents = false
    private var folderWatch: DispatchSourceFileSystemObject?
    private var configWatch: DispatchSourceFileSystemObject?
    private var appWatch: DispatchSourceFileSystemObject?

    init(system: HelperSystem) {
        self.system = system
        uptimeTimer = DispatchSource.makeTimerSource(queue: queue)
        wallTimer = DispatchSource.makeTimerSource(queue: queue)
    }

    /// Starts everything. Call `dispatchMain()` after it.
    func start() {
        // The handlers below take over from the default, which would end the process without
        // clearing the flag.
        for signal in HelperSystem.handledSignals {
            Darwin.signal(signal, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signal, queue: queue)
            source.setEventHandler { [self] in stop() }
            source.activate()
            signals.append(source)
        }
        queue.async { [self] in
            // Keep the timer across restarts and updates, so one with the lid closed carries on
            // counting rather than starting over or losing track.
            engine.state = system.loadState()
            savedState = engine.state.serialized
            for timer in [uptimeTimer, wallTimer] {
                timer.setEventHandler { [self] in tick() }
                timer.activate()
            }
            if system.fake == nil {
                lidEvents = watchLid()
                system.log(lidEvents ? "Started. Watching the lid, power and config." : "Started, but could not watch the lid. Checking every 10 seconds.")
                watchPower()
            }
            watchFiles()
            tick()
        }
    }

    // MARK: One reading

    private func tick() {
        let inputs = system.readInputs()
        let status = engine.tick(inputs, perform: system.perform, log: system.log)

        let state = engine.state.serialized
        if state != savedState, HelperSystem.writeAtomically(Array(state.utf8), to: system.statePath, mode: 0o600) {
            savedState = state
        }
        publish(status)

        var delay = LidSleepEngine.secondsUntilNextTick(after: status, state: engine.state)
        // Without lid events, fall back to looking often, as the old helper did.
        if !lidEvents, system.fake == nil, status.enabled { delay = min(delay ?? 10, 10) }
        // The config folder could not be watched, so keep looking for it.
        if folderWatch == nil {
            watchFiles()
            if folderWatch == nil { delay = min(delay ?? LidSleepEngine.heartbeat, LidSleepEngine.heartbeat) }
        }
        // The app was away when its watch was last set up, and may be back.
        if appWatch == nil { watchApp() }
        schedule(delay)
    }

    /// Writes the status when it says something new. The time alone is not news.
    private func publish(_ status: LidSleepStatus) {
        var comparable = status
        comparable.updatedAt = lastStatus?.updatedAt ?? status.updatedAt
        guard comparable != lastStatus else { return }
        if system.writeStatus(status) { lastStatus = status }
    }

    private func schedule(_ seconds: Int?) {
        guard let seconds else {
            uptimeTimer.schedule(deadline: .distantFuture)
            wallTimer.schedule(wallDeadline: .distantFuture)
            return
        }
        // The countdown should end on time. The heartbeat can wait for other work.
        let leeway: DispatchTimeInterval = seconds >= LidSleepEngine.heartbeat ? .seconds(5) : .milliseconds(200)
        uptimeTimer.schedule(deadline: .now() + .seconds(seconds), leeway: leeway)
        wallTimer.schedule(wallDeadline: .now() + .seconds(seconds), leeway: leeway)
    }

    // MARK: Events

    /// Asks the power manager to say when the lid or the clamshell rule changes. It sends other
    /// messages too, so every one just triggers a fresh reading; the message itself is not trusted.
    private func watchLid() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return false }
        IONotificationPortSetDispatchQueue(port, queue)
        var notification: io_object_t = 0
        let callback: IOServiceInterestCallback = { context, _, _, _ in
            guard let context else { return }
            Unmanaged<Daemon>.fromOpaque(context).takeUnretainedValue().tick()
        }
        // The daemon lives as long as the process, so the unretained pointer stays good.
        let result = IOServiceAddInterestNotification(
            port, root, kIOGeneralInterest, callback, Unmanaged.passUnretained(self).toOpaque(), &notification)
        return result == KERN_SUCCESS
    }

    /// Plugging in, unplugging, and each change in the battery level.
    private func watchPower() {
        for name in [kIOPSNotifyPowerSource, kIOPSNotifyAnyPowerSource] {
            var token: Int32 = 0
            notify_register_dispatch(name, &token, queue) { [self] _ in tick() }
        }
    }

    /// Watches the config folder, the config file and the app. Run again whenever one of them
    /// may have been replaced, because a watch follows the file it opened, not the name.
    private func watchFiles() {
        for watch in [folderWatch, configWatch] { watch?.cancel() }
        let folder = system.config.split(separator: "/", omittingEmptySubsequences: false).dropLast().joined(separator: "/")
        // The installer removes the config and writes it again, so a new file can appear here.
        folderWatch = watch(folder.isEmpty ? "." : folder, flags: O_EVTONLY) { [self] _ in
            watchFiles()
            tick()
        }
        // Vibe Kit rewrites this file in place when the switch or the delay changes.
        configWatch = watch(system.config, flags: O_EVTONLY | O_NOFOLLOW) { [self] events in
            if !events.isDisjoint(with: [.delete, .rename, .revoke]) { watchFiles() }
            tick()
        }
        watchApp()
    }

    /// Moving the app to the Trash renames it. An update swaps it for a new one in an instant,
    /// so wait a moment before deciding it is gone.
    private func watchApp() {
        appWatch?.cancel()
        appWatch = system.appPath().flatMap { path in
            watch(String(decoding: path, as: UTF8.self), flags: O_EVTONLY) { [self] _ in
                queue.asyncAfter(deadline: .now() + .seconds(3)) { [self] in
                    watchFiles()
                    tick()
                }
            }
        }
    }

    private func watch(_ path: String, flags: Int32,
                       _ handler: @escaping @Sendable (DispatchSource.FileSystemEvent) -> Void) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, flags | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename, .attrib, .link, .revoke], queue: queue)
        source.setEventHandler { [weak source] in
            if let source { handler(source.data) }
        }
        source.setCancelHandler { close(descriptor) }
        source.activate()
        return source
    }

    // MARK: Stopping

    /// Never leave the Mac unable to sleep: clear the flag on the way out, whatever the state.
    private func stop() {
        if system.perform(.disableSleep(false)) { engine.state.flag = false }
        HelperSystem.writeAtomically(Array(engine.state.serialized.utf8), to: system.statePath, mode: 0o600)
        system.writeStatus(LidSleepStatus(
            enabled: false, minutes: lastStatus?.minutes ?? 0, state: .off,
            updatedAt: system.fake == nil ? Int64(time(nil)) : lastStatus?.updatedAt ?? 0))
        exit(0)
    }
}
