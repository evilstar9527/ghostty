import Foundation

/// A user-configured project the sidebar tracks. Persisted to UserDefaults.
struct SidebarProject: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String
    var rootPath: String
}

/// One git worktree as returned by `git worktree list --porcelain`.
struct GitWorktree: Identifiable, Equatable, Hashable {
    var path: String
    var head: String?
    /// Local branch name without the `refs/heads/` prefix. Nil when detached.
    var branch: String?
    var isBare: Bool
    var isDetached: Bool
    var isLocked: Bool
    var isPrunable: Bool

    var id: String { path }

    /// Human-readable display label for the worktree row.
    var displayLabel: String {
        if isBare { return "(bare)" }
        if let branch { return branch }
        if isDetached, let head { return "detached @ \(head.prefix(7))" }
        return "(unknown)"
    }
}
