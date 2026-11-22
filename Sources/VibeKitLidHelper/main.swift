// Vibe Kit's lid sleep helper. It runs as a root LaunchDaemon and owns `pmset disablesleep`,
// which only root can set: on while the Mac should stay awake after the lid closes, and always
// off again when the timer ends, the battery runs low, the feature is switched off, or this
// program stops. The rules are in VibeKitLidCore's LidSleepEngine; this file only picks a mode.
//
//   (no arguments)        run as the daemon, waking on events
//   --off                 clear the flag and exit
//   --tick <state-file>   take one reading against a state file and exit, for tests

import Darwin
import Dispatch
import Foundation
import VibeKitLidCore

umask(0o077)

guard let system = HelperSystem(environment: ProcessInfo.processInfo.environment) else { exit(2) }
let arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())

if arguments == ["--off"] {
    _ = system.perform(.disableSleep(false))
    exit(0)
} else if arguments.count == 2, arguments[0] == "--tick" {
    var engine = LidSleepEngine(state: HelperSystem.loadState(arguments[1]))
    let status = engine.tick(system.readInputs(), perform: system.perform, log: system.log)
    let saved = HelperSystem.writeAtomically(Array(engine.state.serialized.utf8), to: arguments[1], mode: 0o600)
    system.writeStatus(status)
    exit(saved ? 0 : 1)
} else if !arguments.isEmpty {
    exit(2)
}

let daemon = Daemon(system: system)
daemon.start()
dispatchMain()
