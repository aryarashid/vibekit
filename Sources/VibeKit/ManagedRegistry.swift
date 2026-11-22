import Darwin
import Foundation

/// GUI and headless launches share one registry. Lock a separate inode because atomic JSON writes rename the file.
struct ManagedRegistry {
    let directory: URL
    typealias Entries = [String: ManagedProcess]

    func load() throws -> Entries {
        do {
            let data = try Data(contentsOf: directory.appendingPathComponent("managed.json"))
            return try JSONDecoder().decode(Entries.self, from: data)
        } catch CocoaError.fileReadNoSuchFile { return [:] }
    }

    @discardableResult
    func update(_ change: (inout Entries) -> Void) throws -> Entries {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = open(directory.appendingPathComponent("managed.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(lock) }
        while flock(lock, LOCK_EX) != 0 {
            if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        var entries = try load()
        change(&entries)
        try JSONEncoder().encode(entries).write(to: directory.appendingPathComponent("managed.json"), options: .atomic)
        return entries
    }
}
