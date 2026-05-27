import Foundation

/// Thin wrapper around the `git` CLI to enumerate and mutate worktrees.
/// Synchronous calls are intentionally off the main thread when invoked
/// via Task { } from SwiftUI.
enum WorktreeService {
    /// Where the system git lives on macOS. macOS ships /usr/bin/git as a
    /// stub that invokes the installed Command Line Tools (or Xcode) git.
    private static let gitURL = URL(fileURLWithPath: "/usr/bin/git")

    enum WorktreeError: LocalizedError {
        case gitFailed(exitCode: Int32, stderr: String)
        case notADirectory(String)

        var errorDescription: String? {
            switch self {
            case let .gitFailed(code, msg):
                return "git exited with \(code): \(msg)"
            case let .notADirectory(path):
                return "Not a directory: \(path)"
            }
        }
    }

    struct RemovalResult {
        var branchDeletionWarning: String?
    }

    /// `git -C <root> worktree list --porcelain` parser.
    static func list(in repoRoot: String) throws -> [GitWorktree] {
        let (stdout, stderr, code) = try runGit(
            ["-C", repoRoot, "worktree", "list", "--porcelain"]
        )
        guard code == 0 else {
            throw WorktreeError.gitFailed(exitCode: code, stderr: stderr)
        }
        return parsePorcelain(stdout)
    }

    /// `git -C <root> worktree add [-b <newBranch>] <path> <ref>`
    /// If `createBranch` is true, `-b <branch>` is added.
    static func add(
        in repoRoot: String,
        path: String,
        ref: String,
        createBranch: Bool,
        newBranchName: String?
    ) throws {
        let parent = (path as NSString).deletingLastPathComponent
        if !parent.isEmpty {
            try FileManager.default.createDirectory(
                atPath: parent,
                withIntermediateDirectories: true
            )
        }

        var args = ["-C", repoRoot, "worktree", "add"]
        if createBranch, let newBranchName, !newBranchName.isEmpty {
            args.append(contentsOf: ["-b", newBranchName])
        }
        args.append(path)
        if !ref.isEmpty {
            args.append(ref)
        }
        let (_, stderr, code) = try runGit(args)
        guard code == 0 else {
            throw WorktreeError.gitFailed(exitCode: code, stderr: stderr)
        }
    }

    /// `git -C <root> worktree remove <path>`, followed by an optional
    /// `git -C <root> branch -D <branch>`.
    static func remove(
        in repoRoot: String,
        path: String,
        branch: String?,
        deleteLocalBranch: Bool
    ) throws -> RemovalResult {
        let (_, removeStderr, removeCode) = try runGit(
            ["-C", repoRoot, "worktree", "remove", path]
        )
        guard removeCode == 0 else {
            throw WorktreeError.gitFailed(exitCode: removeCode, stderr: removeStderr)
        }

        guard deleteLocalBranch,
              let branch,
              !branch.isEmpty else {
            return .init()
        }

        let (_, branchStderr, branchCode) = try runGit(
            ["-C", repoRoot, "branch", "-D", branch]
        )
        guard branchCode == 0 else {
            return .init(
                branchDeletionWarning: "Workspace deleted, but branch deletion failed: git exited with \(branchCode): \(branchStderr)"
            )
        }

        return .init()
    }

    /// `git -C <root> for-each-ref --format=%(refname:short)` for branches.
    /// Used to populate the "base ref" dropdown in the New Worktree sheet.
    static func refs(in repoRoot: String) throws -> [String] {
        let (branches, _, _) = try runGit(
            ["-C", repoRoot, "for-each-ref",
             "--format=%(refname:short)",
             "refs/heads/", "refs/remotes/"]
        )
        return branches
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasSuffix("/HEAD") }
    }

    // MARK: - Internal

    private static func runGit(_ args: [String]) throws -> (stdout: String, stderr: String, code: Int32) {
        let p = Process()
        p.executableURL = gitURL
        p.arguments = args
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()

        let stdout = DataBox()
        let stderr = DataBox()
        let readers = DispatchGroup()

        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stdout.data = out.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }

        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stderr.data = err.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }

        p.waitUntilExit()
        readers.wait()
        let so = String(data: stdout.data, encoding: .utf8) ?? ""
        let se = String(data: stderr.data, encoding: .utf8) ?? ""
        return (so, se, p.terminationStatus)
    }

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        var data: Data {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storage
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                storage = newValue
            }
        }
    }

    /// Porcelain format: each worktree is a block separated by a blank line.
    /// Lines we care about:
    ///   worktree <abs path>
    ///   HEAD <sha>
    ///   branch refs/heads/<name>
    ///   bare
    ///   detached
    ///   locked [reason]
    ///   prunable [reason]
    static func parsePorcelain(_ text: String) -> [GitWorktree] {
        var results: [GitWorktree] = []
        var cur: PartialWT?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty {
                if let c = cur, let path = c.path {
                    results.append(c.finalize(path: path))
                }
                cur = nil
                continue
            }
            if line.hasPrefix("worktree ") {
                if let c = cur, let path = c.path {
                    results.append(c.finalize(path: path))
                }
                cur = PartialWT(path: String(line.dropFirst("worktree ".count)))
            } else if line.hasPrefix("HEAD ") {
                cur?.head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                let full = String(line.dropFirst("branch ".count))
                let short = full.hasPrefix("refs/heads/") ? String(full.dropFirst("refs/heads/".count)) : full
                cur?.branch = short
            } else if line == "bare" {
                cur?.isBare = true
            } else if line == "detached" {
                cur?.isDetached = true
            } else if line.hasPrefix("locked") {
                cur?.isLocked = true
            } else if line.hasPrefix("prunable") {
                cur?.isPrunable = true
            }
        }
        if let c = cur, let path = c.path {
            results.append(c.finalize(path: path))
        }
        return results
    }

    private struct PartialWT {
        var path: String?
        var head: String?
        var branch: String?
        var isBare = false
        var isDetached = false
        var isLocked = false
        var isPrunable = false

        func finalize(path: String) -> GitWorktree {
            GitWorktree(
                path: path,
                head: head,
                branch: branch,
                isBare: isBare,
                isDetached: isDetached,
                isLocked: isLocked,
                isPrunable: isPrunable
            )
        }
    }
}
