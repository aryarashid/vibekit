import Foundation

/// Names a folder by its git repository, reading `.git` files directly instead of running git.
public enum ProjectResolver {
    public static func resolve(_ directory: String, home: String = NSHomeDirectory()) -> Project {
        let fm = FileManager.default
        var dir = directory
        while dir != "/" && dir != home && !dir.isEmpty {
            let dotGit = (dir as NSString).appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit, isDirectory: &isDir) {
                return project(directory: directory, root: dir, dotGit: dotGit, isDirectory: isDir.boolValue)
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return Project(name: (directory as NSString).lastPathComponent, root: directory, subpath: nil, branch: nil, worktree: nil)
    }

    private static func project(directory: String, root: String, dotGit: String, isDirectory: Bool) -> Project {
        var gitDir = dotGit
        var name = (root as NSString).lastPathComponent
        var worktree: String?

        if !isDirectory {
            // Linked worktree or submodule: `.git` is a file that points at the real git dir.
            guard let contents = try? String(contentsOfFile: dotGit, encoding: .utf8),
                  let line = contents.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else {
                return Project(name: name, root: root, subpath: subpath(directory, root), branch: nil, worktree: nil)
            }
            var target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            if !target.hasPrefix("/") { target = (root as NSString).appendingPathComponent(target) }
            gitDir = target
            if let range = target.range(of: "/.git/worktrees/") {
                name = ((String(target[..<range.lowerBound])) as NSString).lastPathComponent
                worktree = (root as NSString).lastPathComponent
            } else if let range = target.range(of: "/worktrees/", options: .backwards),
                      FileManager.default.fileExists(atPath: (target as NSString).appendingPathComponent("commondir")) {
                // A worktree of a bare repository, such as `myrepo.git/worktrees/feature`.
                let common = (String(target[..<range.lowerBound]) as NSString).lastPathComponent
                name = common.hasSuffix(".git") ? String(common.dropLast(4)) : common
                worktree = (root as NSString).lastPathComponent
            }
        }

        return Project(name: name, root: root, subpath: subpath(directory, root), branch: branch(gitDir: gitDir), worktree: worktree)
    }

    public static func branch(gitDir: String) -> String? {
        let head = (gitDir as NSString).appendingPathComponent("HEAD")
        guard let contents = try? String(contentsOfFile: head, encoding: .utf8) else { return nil }
        let line = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("ref: refs/heads/") { return String(line.dropFirst("ref: refs/heads/".count)) }
        if line.count >= 7, !line.hasPrefix("ref:") { return String(line.prefix(7)) }
        return nil
    }

    private static func subpath(_ directory: String, _ root: String) -> String? {
        guard directory.count > root.count, directory.hasPrefix(root + "/") else { return nil }
        return String(directory.dropFirst(root.count + 1))
    }
}
