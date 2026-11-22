import CryptoKit
import Foundation
import IOKit
import Security
import VibeKitCore

/// Keeps a laptop awake for a while after its lid closes, so agents and builds can finish.
///
/// macOS sleeps the moment the lid closes unless the root-only `pmset disablesleep` flag is
/// already set. Vibe Kit cannot hold that flag itself: if it crashed or quit while the flag was
/// on, the Mac would stay awake in a bag. So a small root LaunchDaemon owns the flag and the
/// timer, and clears the flag whenever it stops. The app only installs it once and writes the
/// number of minutes to a config file the daemon reads.
///
/// The daemon is the `VibeKitLidHelper` program in this package. Its rules live in
/// `LidSleepEngine`; this file is the app's side: installing it, and reading what it reports.
enum LidSleep {
    static let label = "dev.vibekit.lid-sleep"
    static let helperPath = "/Library/PrivilegedHelperTools/dev.vibekit.lid-sleep"
    static let plistPath = "/Library/LaunchDaemons/dev.vibekit.lid-sleep.plist"
    static let configDirectory = "/Library/Application Support/Vibe Kit"
    static let configPath = configDirectory + "/lid-sleep-minutes"
    /// Root's file naming the app, so the helper goes idle if the app is moved to the Trash.
    static let appPathFile = configDirectory + "/app-path"
    /// Where the helper keeps its timer across restarts.
    static let statePath = "/var/run/dev.vibekit.lid-sleep.state"
    /// Where the helper says what it is doing, readable by everyone.
    static let statusPath = "/var/run/dev.vibekit.lid-sleep.status"

    static let choices = LidSleepEngine.choices
    static let defaultMinutes = 45

    static let helperName = "VibeKitLidHelper"
    /// The identifier scripts/build-app.sh signs the helper with.
    static let helperIdentifier = "dev.vibekit.lid-sleep"
    /// The installer carries the helper inside one shell command, and a command has a size
    /// limit of about a megabyte. Base64 adds a third, so stop well short of that.
    static let maxHelperBytes = 600 * 1024

    /// The helper program inside the app bundle, or next to this binary for `swift run`
    /// (run `swift build` first, which builds both).
    static var bundledHelper: URL? {
        let fm = FileManager.default
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(helperName)")
        if fm.fileExists(atPath: bundled.path) { return bundled }
        #if DEBUG
        if let sibling = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(helperName),
           fm.fileExists(atPath: sibling.path) { return sibling }
        #endif
        return nil
    }

    /// A helper that is safe to hand to root: its bytes, and the signature root must find on them.
    struct VerifiedHelper {
        let data: Data
        /// nil for a build that is not signed by a team, where there is nothing to compare with.
        let requirement: String?
    }

    /// The bundled helper, only if it was signed by the same team as this app.
    ///
    /// The app bundle is writable by the user, so anything in it could have been swapped. A
    /// released app is signed with a Developer ID, and nobody else can sign a helper as that
    /// team, so the helper has to carry that team's valid signature. Root checks it again on
    /// the exact bytes it wrote (see `installCommand`), which is the check that counts: the one
    /// here can be raced by swapping the file after it, and only gives an early, clear failure.
    ///
    /// A build with no team (ad hoc, or `swift run`) has no identity to compare with, so there
    /// the helper is only as trustworthy as the bundle it sits in.
    static func verifiedHelper() -> VerifiedHelper? {
        guard let url = bundledHelper else { return nil }
        var requirement: String?
        switch ownTeam() {
        case .unreadable:
            return nil
        case .none:
            break
        case .team(let team):
            guard let text = helperRequirement(teamID: team), helperIsSigned(at: url, by: team, requirement: text) else { return nil }
            requirement = text
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty, data.count <= maxHelperBytes else { return nil }
        return VerifiedHelper(data: data, requirement: requirement)
    }

    enum Team: Equatable {
        case none, team(String), unreadable
    }

    /// The team that signed the running app, from its own signature.
    static func ownTeam() -> Team {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return .unreadable }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return .unreadable }
        return team(of: staticCode)
    }

    private static func team(of code: SecStaticCode) -> Team {
        var info: CFDictionary?
        let status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        if status == errSecCSUnsigned { return .none }
        guard status == errSecSuccess, let info = info as? [String: Any] else { return .unreadable }
        guard let team = info[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else { return .none }
        return .team(team)
    }

    /// What the helper's signature must satisfy, in the code requirement language. nil if the
    /// team is not a plain Team ID, so nothing odd is ever put into the requirement or the shell.
    nonisolated static func helperRequirement(teamID: String) -> String? {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        guard teamID.count == 10, teamID.allSatisfy(allowed.contains) else { return nil }
        return "identifier \"\(helperIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// Whether the file has a valid signature that meets the requirement and names this team.
    static func helperIsSigned(at url: URL, by team: String, requirement text: String) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else { return false }
        return Self.team(of: code) == .team(team)
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
    /// Compared byte for byte with the bundled one, so an older helper, the shell script before
    /// it, or one that was changed all count as outdated.
    static func helperState() -> HelperState {
        let fm = FileManager.default
        guard fm.fileExists(atPath: plistPath), let installed = fm.contents(atPath: helperPath) else { return .missing }
        return helperState(installed: installed, bundled: bundledHelper.flatMap { try? Data(contentsOf: $0) },
                           installedFor: installedAppPath(), appPath: Bundle.main.bundlePath)
    }

    nonisolated static func helperState(installed: Data, bundled: Data?, installedFor: String?, appPath: String) -> HelperState {
        guard let bundled else { return .outdated }
        return sha256(installed) == sha256(bundled) && installedFor == appPath ? .current : .outdated
    }

    /// The app the installed helper belongs to.
    static func installedAppPath() -> String? {
        FileManager.default.contents(atPath: appPathFile).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Whether that app is still there. The helper does nothing once it is gone.
    static func installedAppExists() -> Bool {
        guard let path = installedAppPath(), !path.isEmpty else { return true }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// What the running helper last reported, or nil if it has not written anything. The shell
    /// helper that came before this one never does.
    static func readStatus() -> LidSleepStatus? {
        FileManager.default.contents(atPath: statusPath).flatMap(LidSleepStatus.decode)
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
        guard let data = FileManager.default.contents(atPath: configPath) else { return 0 }
        return LidSleepEngine.parseMinutes(data) ?? 0
    }

    /// The helper's own rule: one of the exact choices, written plainly.
    nonisolated static func parseMinutes(_ text: String) -> Int {
        LidSleepEngine.parseMinutes(Array(text.utf8)) ?? 0
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
        let command = installCommand(helper: helper.data, requirement: helper.requirement, minutes: minutes,
                                     uid: getuid(), appPath: Bundle.main.bundlePath)
        return await runAsAdmin(command, prompt: "Vibe Kit wants to install a small helper that keeps your Mac awake for a while after you close the lid.")
    }

    /// Removes the daemon. Stopping it clears the sleep flag, and the last line makes sure.
    static func uninstall() async -> Bool {
        let command = [
            "set -e",
            "/bin/launchctl bootout system/\(label) 2>/dev/null || true",
            waitUntilUnloaded,
            "/bin/rm -f \(shellQuote(plistPath)) \(shellQuote(helperPath)) \(shellQuote(configPath)) \(shellQuote(appPathFile)) \(shellQuote(statePath)) \(shellQuote(statusPath))",
            "/usr/bin/pmset -a disablesleep 0",
        ].joined(separator: "\n")
        return await runAsAdmin(command, prompt: "Vibe Kit wants to remove its lid sleep helper.")
    }

    /// `bootout` can return before the old helper has exited, and bootstrapping again too soon fails.
    nonisolated static var waitUntilUnloaded: String {
        "i=0; while /bin/launchctl print system/\(label) >/dev/null 2>&1 && [ $i -lt 50 ]; do i=$((i+1)); /bin/sleep 0.1; done"
    }

    /// The shell command root runs to install the helper. `requirement` is the signature the
    /// helper must carry, from `helperRequirement`; nil skips that check for unsigned builds.
    nonisolated static func installCommand(helper: Data, requirement: String? = nil, minutes: Int, uid: uid_t, appPath: String) -> String {
        let value = choices.contains(minutes) ? minutes : defaultMinutes
        let paths = ["/Library/PrivilegedHelperTools", configDirectory, helperPath, plistPath, configPath, appPathFile]
        let encoded = helper.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        let discard = "{ /bin/rm -f \"$tmp\"; exit 1; }"
        // Root checks the signature of the file it wrote itself, in a folder only root can
        // change, so there is no moment at which the checked file can be swapped for another.
        let signatureCheck = requirement.map {
            "/usr/bin/codesign --verify --strict --all-architectures --test-requirement \(shellQuote("=" + $0)) \"$tmp\" || \(discard)"
        }
        let lines: [String?] = [
            "set -e",
            // Root follows links, so refuse to work through one someone planted.
            "for p in \(paths.map(shellQuote).joined(separator: " ")); do if [ -L \"$p\" ]; then echo \"refusing link $p\" >&2; exit 1; fi; done",
            "/usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools \(shellQuote(configDirectory))",
            // The helper travels inside this command, from the app's memory, never as a path
            // into the bundle the user can change. Root then checks it wrote exactly those bytes.
            "tmp=$(/usr/bin/mktemp /Library/PrivilegedHelperTools/.dev.vibekit.lid-sleep.XXXXXX)",
            "/usr/bin/base64 -D > \"$tmp\" <<'VIBEKIT_HELPER'",
            encoded,
            "VIBEKIT_HELPER",
            "[ \"$(/usr/bin/shasum -a 256 \"$tmp\" | /usr/bin/cut -c1-64)\" = \(sha256(helper)) ] || \(discard)",
            signatureCheck,
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
        ]
        return lines.compactMap { $0 }.joined(separator: "\n")
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
