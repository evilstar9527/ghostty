import Foundation
import SwiftUI

/// Observable model that backs the worktree sidebar across all windows. There
/// is a single shared instance so adding a project once shows it everywhere.
@MainActor
final class SidebarViewModel: ObservableObject {
    /// Shared instance — one per app session, all sidebars observe it.
    static let shared = SidebarViewModel()

    @Published var projects: [SidebarProject] = []
    @Published private(set) var worktrees: [UUID: [GitWorktree]] = [:]
    @Published private(set) var workspaceNames: [String: String] = [:]
    @Published private(set) var managedWorktreePaths: [UUID: Set<String>] = [:]
    @Published var expanded: Set<UUID> = []
    @Published var selectedWorktreePath: String?
    @Published private(set) var loading: Set<UUID> = []
    @Published var lastError: String?

    private let projectsDefaultsKey = "sidebar.projects.v1"
    private let workspaceNamesDefaultsKey = "sidebar.workspaceNames.v1"
    private let managedWorktreePathsDefaultsKey = "sidebar.managedWorktreePaths.v1"

    init() {
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: projectsDefaultsKey),
              let decoded = try? JSONDecoder().decode([SidebarProject].self, from: data) else {
            projects = []
            loadWorkspaceNames()
            loadManagedWorktreePaths()
            return
        }
        projects = decoded
        loadWorkspaceNames()
        loadManagedWorktreePaths()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(projects) {
            UserDefaults.standard.set(data, forKey: projectsDefaultsKey)
        }
    }

    private func loadWorkspaceNames() {
        guard let data = UserDefaults.standard.data(forKey: workspaceNamesDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            workspaceNames = [:]
            return
        }
        workspaceNames = decoded
    }

    private func saveWorkspaceNames() {
        if let data = try? JSONEncoder().encode(workspaceNames) {
            UserDefaults.standard.set(data, forKey: workspaceNamesDefaultsKey)
        }
    }

    private func loadManagedWorktreePaths() {
        guard let data = UserDefaults.standard.data(forKey: managedWorktreePathsDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            managedWorktreePaths = [:]
            return
        }

        managedWorktreePaths = Dictionary(
            uniqueKeysWithValues: decoded.compactMap { key, paths in
                guard let id = UUID(uuidString: key) else { return nil }
                return (id, Set(paths.map(normalizedPath)))
            }
        )
    }

    private func saveManagedWorktreePaths() {
        let encoded = Dictionary(
            uniqueKeysWithValues: managedWorktreePaths.map { id, paths in
                (id.uuidString, Array(paths).sorted())
            }
        )

        if let data = try? JSONEncoder().encode(encoded) {
            UserDefaults.standard.set(data, forKey: managedWorktreePathsDefaultsKey)
        }
    }

    // MARK: - Project mutations

    func addProject(name: String, rootPath: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let path = rootPath.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !path.isEmpty else { return }
        projects.append(SidebarProject(name: trimmed, rootPath: path))
        save()
    }

    func removeProject(_ project: SidebarProject) {
        projects.removeAll { $0.id == project.id }
        worktrees.removeValue(forKey: project.id)
        managedWorktreePaths.removeValue(forKey: project.id)
        expanded.remove(project.id)
        save()
        saveManagedWorktreePaths()
    }

    func updateProject(_ project: SidebarProject) {
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[idx] = project
        save()
    }

    // MARK: - Worktree refresh

    func toggleExpanded(_ project: SidebarProject) {
        if expanded.contains(project.id) {
            expanded.remove(project.id)
        } else {
            expanded.insert(project.id)
            if worktrees[project.id] == nil {
                refresh(project)
            }
        }
    }

    func refresh(_ project: SidebarProject) {
        let id = project.id
        let root = project.rootPath
        loading.insert(id)
        Task.detached { [weak self] in
            let result: Result<[GitWorktree], Error>
            do {
                let list = try WorktreeService.list(in: root)
                result = .success(list)
            } catch {
                result = .failure(error)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.loading.remove(id)
                switch result {
                case let .success(list):
                    self.worktrees[id] = self.visibleWorktrees(from: list, for: id)
                    self.lastError = nil
                case let .failure(err):
                    self.lastError = err.localizedDescription
                }
            }
        }
    }

    func refreshAllExpanded() {
        for p in projects where expanded.contains(p.id) {
            refresh(p)
        }
    }

    func selectWorktree(_ worktree: GitWorktree) {
        selectedWorktreePath = normalizedPath(worktree.path)
    }

    var selectedWorktree: GitWorktree? {
        guard let selectedWorktreePath else { return nil }

        for list in worktrees.values {
            if let worktree = list.first(where: {
                normalizedPath($0.path) == selectedWorktreePath
            }) {
                return worktree
            }
        }

        return nil
    }

    func isSelected(_ worktree: GitWorktree) -> Bool {
        guard let selectedWorktreePath else { return false }
        return normalizedPath(worktree.path) == selectedWorktreePath
    }

    func displayName(for worktree: GitWorktree) -> String {
        let key = normalizedPath(worktree.path)
        if let name = workspaceNames[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return worktree.displayLabel
    }

    func secondaryLabel(for worktree: GitWorktree) -> String {
        let display = displayName(for: worktree)
        if display == worktree.displayLabel {
            return worktree.path
        }
        return "\(worktree.displayLabel) - \(worktree.path)"
    }

    func renameWorkspace(for worktree: GitWorktree, to name: String) {
        let key = normalizedPath(worktree.path)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            workspaceNames.removeValue(forKey: key)
        } else {
            workspaceNames[key] = trimmed
        }

        saveWorkspaceNames()
    }

    func createWorktree(
        in project: SidebarProject,
        path: String,
        ref: String,
        createBranch: Bool,
        newBranchName: String?,
        workspaceName: String?
    ) async -> Result<Void, Error> {
        do {
            try WorktreeService.add(
                in: project.rootPath,
                path: path,
                ref: ref,
                createBranch: createBranch,
                newBranchName: newBranchName
            )
            let trimmedWorkspace = workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            await MainActor.run {
                self.markManagedWorktree(path: path, projectID: project.id)
                if !trimmedWorkspace.isEmpty {
                    self.workspaceNames[self.normalizedPath(path)] = trimmedWorkspace
                    self.saveWorkspaceNames()
                }
                self.refresh(project)
            }
            return .success(())
        } catch {
            await MainActor.run { self.lastError = error.localizedDescription }
            return .failure(error)
        }
    }

    func deleteWorkspace(
        _ worktree: GitWorktree,
        in project: SidebarProject,
        deleteLocalBranch: Bool
    ) async -> Result<Void, Error> {
        do {
            try WorktreeService.remove(
                in: project.rootPath,
                path: worktree.path,
                branch: worktree.branch,
                deleteLocalBranch: deleteLocalBranch
            )

            await MainActor.run {
                self.unmarkManagedWorktree(path: worktree.path, projectID: project.id)
                self.workspaceNames.removeValue(forKey: self.normalizedPath(worktree.path))
                self.saveWorkspaceNames()
                if self.selectedWorktreePath == self.normalizedPath(worktree.path) {
                    self.selectedWorktreePath = nil
                }
                self.refresh(project)
            }
            return .success(())
        } catch {
            await MainActor.run { self.lastError = error.localizedDescription }
            return .failure(error)
        }
    }

    private func normalizedPath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    private func visibleWorktrees(from list: [GitWorktree], for projectID: UUID) -> [GitWorktree] {
        let namedPaths = Set(workspaceNames.keys.map(normalizedPath))
        let managedPaths = managedWorktreePaths[projectID, default: []].union(namedPaths)
        return list.filter { managedPaths.contains(normalizedPath($0.path)) }
    }

    private func markManagedWorktree(path: String, projectID: UUID) {
        var paths = managedWorktreePaths[projectID, default: []]
        paths.insert(normalizedPath(path))
        managedWorktreePaths[projectID] = paths
        saveManagedWorktreePaths()
    }

    private func unmarkManagedWorktree(path: String, projectID: UUID) {
        var paths = managedWorktreePaths[projectID, default: []]
        paths.remove(normalizedPath(path))
        if paths.isEmpty {
            managedWorktreePaths.removeValue(forKey: projectID)
        } else {
            managedWorktreePaths[projectID] = paths
        }
        saveManagedWorktreePaths()
    }
}
