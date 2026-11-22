import Foundation
import IOKit

/// Keeps a laptop awake for a while after its lid closes, so agents and builds can finish.
///
/// macOS sleeps the moment the lid closes unless the root-only `pmset disablesleep` flag is
/// already set. Vibe Kit cannot hold that flag itself: if it crashed or quit while the flag was
/// on, the Mac would stay awake in a bag. So a small root LaunchDaemon owns the flag and the
/// timer, and clears the flag whenever it stops. The app only installs it once and writes the
/// number of minutes to a config file the daemon reads.
enum LidSleep {
    static let label = "dev.vibekit.lid-sleep"
    static let helperPath = "/Library/PrivilegedHelperTools/dev.vibekit.lid-sleep"
    static let plistPath = "/Library/LaunchDaemons/dev.vibekit.lid-sleep.plist"
    static let configDirectory = "/Library/Application Support/Vibe Kit"
    static let configPath = configDirectory + "/lid-sleep-minutes"

    static let choices = [15, 30, 45, 60]
    static let defaultMinutes = 45

    /// The helper script inside the app bundle, or next to the sources for `swift run`.
    static var bundledHelper: URL? {
        if let url = Bundle.main.url(forResource: "lid-sleep-helper", withExtension: "sh") { return url }
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/lid-sleep-helper.sh")
        return FileManager.default.fileExists(atPath: source.path) ? source : nil
    }

    /// Only Macs with a lid report a clamshell state.
    static let isSupported: Bool = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0) != nil
    }()

    enum HelperState: Equatable {
        case missing, outdated, current
    }

    /// Whether the installed helper is the one this copy of Vibe Kit ships.
    static func helperState() -> HelperState {
        let fm = FileManager.default
        guard fm.fileExists(atPath: plistPath), let installed = fm.contents(atPath: helperPath) else { return .missing }
        guard let bundled = bundledHelper.flatMap({ try? Data(contentsOf: $0) }) else { return .current }
        return installed == bundled ? .current : .outdated
    }

    /// The minutes the daemon will use, read the same strict way it reads them. 0 means off.
    static func readMinutes() -> Int {
        guard let data = FileManager.default.contents(atPath: configPath) else { return 0 }
        return parseMinutes(String(decoding: data.prefix(16), as: UTF8.self))
    }

    nonisolated static func parseMinutes(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Same rule as the helper: one of the exact choices, written plainly.
        return choices.first { String($0) == trimmed } ?? 0
    }

    /// Rewrites the config in place. The folder is root's, so the file cannot be swapped for a
    /// link, and the installer made the file itself ours so this needs no password.
    static func writeMinutes(_ minutes: Int) -> Bool {
        let value = choices.contains(minutes) ? minutes : 0
        guard let handle = FileHandle(forWritingAtPath: configPath) else { return false }
        defer { try? handle.close() }
        do {
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data("\(value)\n".utf8))
            return true
        } catch {
            NSLog("Vibe Kit: could not write lid sleep config: \(error.localizedDescription)")
            return false
        }
    }

    /// Installs or updates the daemon with one administrator prompt. Returns false if the user
    /// cancels or anything fails. Runs off the main thread because the prompt blocks.
    static func install(minutes: Int) async -> Bool {
        guard let helper = bundledHelper else { return false }
        let command = installCommand(helper: helper.path, minutes: minutes, uid: getuid())
        return await runAsAdmin(command, prompt: "Vibe Kit wants to install a small helper that keeps your Mac awake for a while after you close the lid.")
    }

    /// Removes the daemon. Stopping it clears the sleep flag, and the last line makes sure.
    static func uninstall() async -> Bool {
        let command = [
            "/bin/launchctl bootout system/\(label) 2>/dev/null",
            "/bin/rm -f \(shellQuote(plistPath)) \(shellQuote(helperPath)) \(shellQuote(configPath))",
            "/usr/bin/pmset -a disablesleep 0",
        ].joined(separator: "; ")
        return await runAsAdmin(command, prompt: "Vibe Kit wants to remove its lid sleep helper.")
    }

    nonisolated static func installCommand(helper: String, minutes: Int, uid: uid_t) -> String {
        let value = choices.contains(minutes) ? minutes : defaultMinutes
        return [
            "set -e",
            "/usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools \(shellQuote(configDirectory))",
            // Copy, never run from the bundle: the app is writable by the user, and root must not
            // run a file the user can change.
            "/usr/bin/install -o root -g wheel -m 755 \(shellQuote(helper)) \(shellQuote(helperPath))",
            "/bin/rm -f \(shellQuote(configPath))",
            "/usr/bin/printf '%s\\n' \(value) > \(shellQuote(configPath))",
            "/usr/sbin/chown \(uid) \(shellQuote(configPath))",
            "/bin/chmod 644 \(shellQuote(configPath))",
            "/usr/bin/printf '%s' \(shellQuote(launchdPlist)) > \(shellQuote(plistPath))",
            "/usr/sbin/chown root:wheel \(shellQuote(plistPath))",
            "/bin/chmod 644 \(shellQuote(plistPath))",
            "/bin/launchctl bootout system/\(label) 2>/dev/null || true",
            "/bin/launchctl bootstrap system \(shellQuote(plistPath))",
        ].joined(separator: "\n")
    }

    nonisolated static var launchdPlist: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/bin/bash</string>
                <string>\(helperPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ProcessType</key>
            <string>Background</string>
        </dict>
        </plist>

        """
    }

    nonisolated static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func runAsAdmin(_ command: String, prompt: String) async -> Bool {
        let script = "do shell script \(appleScriptString(command)) with prompt \(appleScriptString(prompt)) with administrator privileges"
        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                NSLog("Vibe Kit: lid sleep helper change failed to start: \(error.localizedDescription)")
                return false
            }
            if process.terminationStatus != 0 {
                let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                NSLog("Vibe Kit: lid sleep helper change failed: \(message)")
            }
            return process.terminationStatus == 0
        }.value
    }
}
