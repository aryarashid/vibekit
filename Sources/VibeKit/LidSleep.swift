import CryptoKit
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
    /// Root's file naming the app, so the helper goes idle if the app is moved to the Trash.
    static let appPathFile = configDirectory + "/app-path"

    static let choices = [15, 30, 45, 60]
    static let defaultMinutes = 45

    /// SHA-256 of Resources/lid-sleep-helper.sh. The app bundle is writable by the user, so the
    /// installer only hands root a script with exactly this hash. A test keeps it in step.
    static let helperSHA256 = "a14b75a7f78ec29fa3277e82fa97b2a54883d812df0fe84312ef0f3144662797"

    /// The helper script inside the app bundle, or next to the sources for `swift run`.
    static var bundledHelper: URL? {
        if let url = Bundle.main.url(forResource: "lid-sleep-helper", withExtension: "sh") { return url }
        #if DEBUG
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/lid-sleep-helper.sh")
        return FileManager.default.fileExists(atPath: source.path) ? source : nil
        #else
        return nil
        #endif
    }

    /// The bundled helper's bytes, only if they are the ones this build was made with.
    static func verifiedHelper() -> Data? {
        guard let data = bundledHelper.flatMap({ try? Data(contentsOf: $0) }), sha256(data) == helperSHA256 else { return nil }
        return data
    }

    nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

    /// Whether the installed helper is the one this copy of Vibe Kit ships, for this copy's location.
    static func helperState() -> HelperState {
        let fm = FileManager.default
        guard fm.fileExists(atPath: plistPath), let installed = fm.contents(atPath: helperPath) else { return .missing }
        let app = fm.contents(atPath: appPathFile).map { String(decoding: $0, as: UTF8.self) }
        return sha256(installed) == helperSHA256 && app == Bundle.main.bundlePath ? .current : .outdated
    }

    /// Whether launchd has the helper loaded. Files on disk alone do not mean it is running.
    static func isLoaded() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/\(label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// The minutes the daemon will use, read the same strict way it reads them. 0 means off.
    static func readMinutes() -> Int {
        guard let data = FileManager.default.contents(atPath: configPath), data.count <= 16 else { return 0 }
        return parseMinutes(String(decoding: data, as: UTF8.self))
    }

    nonisolated static func parseMinutes(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Same rule as the helper: one of the exact choices, written plainly.
        return choices.first { String($0) == trimmed } ?? 0
    }

    /// Rewrites the config in place. The folder is root's, so the file cannot be swapped for a
    /// link, and the installer made the file itself ours so this needs no password. It writes
    /// first and trims after, so the helper never reads an empty file in between.
    static func writeMinutes(_ minutes: Int) -> Bool {
        let value = choices.contains(minutes) ? minutes : 0
        guard let handle = FileHandle(forWritingAtPath: configPath) else { return false }
        defer { try? handle.close() }
        let data = Data("\(value)\n".utf8)
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: data)
            try handle.truncate(atOffset: UInt64(data.count))
            return true
        } catch {
            NSLog("Vibe Kit: could not write lid sleep config: \(error.localizedDescription)")
            return false
        }
    }

    /// Installs or updates the daemon with one administrator prompt. Returns false if the user
    /// cancels or anything fails. Runs off the main thread because the prompt blocks.
    static func install(minutes: Int) async -> Bool {
        guard let helper = verifiedHelper() else {
            NSLog("Vibe Kit: the bundled lid sleep helper is missing or changed, so it was not installed")
            return false
        }
        let command = installCommand(helper: helper, minutes: minutes, uid: getuid(), appPath: Bundle.main.bundlePath)
        return await runAsAdmin(command, prompt: "Vibe Kit wants to install a small helper that keeps your Mac awake for a while after you close the lid.")
    }

    /// Removes the daemon. Stopping it clears the sleep flag, and the last line makes sure.
    static func uninstall() async -> Bool {
        let command = [
            "set -e",
            "/bin/launchctl bootout system/\(label) 2>/dev/null || true",
            waitUntilUnloaded,
            "/bin/rm -f \(shellQuote(plistPath)) \(shellQuote(helperPath)) \(shellQuote(configPath)) \(shellQuote(appPathFile))",
            "/usr/bin/pmset -a disablesleep 0",
        ].joined(separator: "\n")
        return await runAsAdmin(command, prompt: "Vibe Kit wants to remove its lid sleep helper.")
    }

    /// `bootout` can return before the old helper has exited, and bootstrapping again too soon fails.
    nonisolated static var waitUntilUnloaded: String {
        "i=0; while /bin/launchctl print system/\(label) >/dev/null 2>&1 && [ $i -lt 50 ]; do i=$((i+1)); /bin/sleep 0.1; done"
    }

    nonisolated static func installCommand(helper: Data, minutes: Int, uid: uid_t, appPath: String) -> String {
        let value = choices.contains(minutes) ? minutes : defaultMinutes
        let paths = ["/Library/PrivilegedHelperTools", configDirectory, helperPath, plistPath, configPath, appPathFile]
        let encoded = helper.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return [
            "set -e",
            // Root follows links, so refuse to work through one someone planted.
            "for p in \(paths.map(shellQuote).joined(separator: " ")); do if [ -L \"$p\" ]; then echo \"refusing link $p\" >&2; exit 1; fi; done",
            "/usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools \(shellQuote(configDirectory))",
            // The script travels inside this command, from the signed app's memory after its hash
            // was checked, never as a path into the bundle the user can change.
            "tmp=$(/usr/bin/mktemp /Library/PrivilegedHelperTools/.dev.vibekit.lid-sleep.XXXXXX)",
            "/usr/bin/base64 -D > \"$tmp\" <<'VIBEKIT_HELPER'",
            encoded,
            "VIBEKIT_HELPER",
            "[ \"$(/usr/bin/shasum -a 256 \"$tmp\" | /usr/bin/cut -c1-64)\" = \(helperSHA256) ] || { /bin/rm -f \"$tmp\"; exit 1; }",
            "/usr/sbin/chown root:wheel \"$tmp\"",
            "/bin/chmod 755 \"$tmp\"",
            "/bin/mv -f \"$tmp\" \(shellQuote(helperPath))",
            "/bin/rm -f \(shellQuote(configPath)) \(shellQuote(appPathFile)) \(shellQuote(plistPath))",
            "/usr/bin/printf '%s\\n' \(value) > \(shellQuote(configPath))",
            "/usr/sbin/chown \(uid) \(shellQuote(configPath))",
            "/bin/chmod 644 \(shellQuote(configPath))",
            "/usr/bin/printf '%s' \(shellQuote(appPath)) > \(shellQuote(appPathFile))",
            "/bin/chmod 644 \(shellQuote(appPathFile))",
            "/usr/bin/printf '%s' \(shellQuote(launchdPlist)) > \(shellQuote(plistPath))",
            "/usr/sbin/chown root:wheel \(shellQuote(plistPath))",
            "/bin/chmod 644 \(shellQuote(plistPath))",
            "/bin/launchctl bootout system/\(label) 2>/dev/null || true",
            waitUntilUnloaded,
            "/bin/launchctl enable system/\(label)",
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
            <key>AssociatedBundleIdentifiers</key>
            <array>
                <string>dev.vibekit.VibeKit</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
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
            } catch {
                NSLog("Vibe Kit: lid sleep helper change failed to start: \(error.localizedDescription)")
                return false
            }
            let message = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                NSLog("Vibe Kit: lid sleep helper change failed: \(String(decoding: message, as: UTF8.self))")
            }
            return process.terminationStatus == 0
        }.value
    }
}
