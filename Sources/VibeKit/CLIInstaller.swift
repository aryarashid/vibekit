import Foundation

/// Installs only a symlink. Existing files and links to a different executable belong to their owners.
struct CLIInstaller {
    enum Status: Equatable {
        case installed(URL), notInstalled, conflict(URL)
    }

    let executable: URL
    let directory: URL
    private var link: URL { directory.appendingPathComponent("vibekit") }

    init(executable: URL, directory: URL) {
        self.executable = executable.standardizedFileURL.resolvingSymlinksInPath()
        self.directory = directory
    }

    init() {
        let local = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        let system = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        // Honor an existing user link even if /usr/local/bin became writable later.
        let user = Self(executable: executable, directory: local)
        if user.status() != .notInstalled || !FileManager.default.isWritableFile(atPath: system.path) {
            self = user
        } else {
            self.init(executable: executable, directory: system)
        }
    }

    func status() -> Status {
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) {
            let absolute = URL(fileURLWithPath: target, relativeTo: link.deletingLastPathComponent()).standardizedFileURL
            return absolute.resolvingSymlinksInPath().path == executable.path ? .installed(link) : .conflict(link)
        }
        return FileManager.default.fileExists(atPath: link.path) ? .conflict(link) : .notInstalled
    }

    @discardableResult func install() throws -> Status {
        let existing = status()
        guard existing == .notInstalled else { return existing }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: executable.path)
        } catch CocoaError.fileWriteFileExists { return status() }
        return .installed(link)
    }

    @discardableResult func uninstall() throws -> Status {
        let existing = status()
        guard existing == .installed(link) else { return existing }
        guard unlink(link.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return .notInstalled
    }
}
