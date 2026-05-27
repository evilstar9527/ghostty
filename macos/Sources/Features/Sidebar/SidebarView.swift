import SwiftUI

/// The worktree sidebar. Shows a list of user-configured projects, each
/// expandable to its `git worktree list` output. Clicking "Open" on a row
/// fires a tab-open notification with the worktree path as the cwd.
struct WorktreeSidebarView: View {
    @ObservedObject private var model = SidebarViewModel.shared

    /// Invoked with the absolute path of a worktree to open in a new tab.
    var openWorktree: (String, String?) -> Void

    @State private var showingProjectSheet: Bool = false
    @State private var newWorktreeFor: SidebarProject?
    @State private var renamingWorkspace: RenameWorkspaceRequest?
    @State private var deletingWorkspace: DeleteWorkspaceRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(NSColor.windowBackgroundColor))
        .sheet(isPresented: $showingProjectSheet) {
            ProjectManagementSheet(model: model)
        }
        .sheet(item: $newWorktreeFor) { project in
            NewWorktreeSheet(project: project, model: model)
        }
        .sheet(item: $renamingWorkspace) { request in
            RenameWorkspaceSheet(
                worktree: request.worktree,
                initialName: request.initialName,
                model: model
            )
        }
        .sheet(item: $deletingWorkspace) { request in
            DeleteWorkspaceSheet(
                project: request.project,
                worktree: request.worktree,
                displayName: request.displayName,
                model: model
            )
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Worktrees")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button {
                model.refreshAllExpanded()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh worktrees")
            Button {
                showingProjectSheet = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Add or manage projects")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var content: some View {
        if model.projects.isEmpty {
            VStack(spacing: 8) {
                Text("No projects yet")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Button("Add Project…") { showingProjectSheet = true }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(model.projects) { project in
                    projectSection(project)
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private func projectSection(_ project: SidebarProject) -> some View {
        let expanded = Binding<Bool>(
            get: { model.expanded.contains(project.id) },
            set: { _ in model.toggleExpanded(project) }
        )
        DisclosureGroup(isExpanded: expanded) {
            if model.loading.contains(project.id) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading…").foregroundColor(.secondary).font(.caption)
                }
            } else if let worktrees = model.worktrees[project.id], !worktrees.isEmpty {
                ForEach(worktrees) { wt in
                    worktreeRow(wt, project: project)
                }
                Button {
                    newWorktreeFor = project
                } label: {
                    Label("New Worktree…", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            } else {
                Text("No workspaces yet")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button {
                    newWorktreeFor = project
                } label: {
                    Label("New Worktree…", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        } label: {
            HStack {
                Text(project.name).bold()
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .contentShape(Rectangle())
        }
    }

    private func worktreeRow(_ wt: GitWorktree, project: SidebarProject) -> some View {
        let title = model.displayName(for: wt)
        let subtitle = model.secondaryLabel(for: wt)
        let isSelected = model.isSelected(wt)

        return HStack(alignment: .top, spacing: 8) {
            Button {
                model.selectWorktree(wt)
                openWorktree(wt.path, nil)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .layoutPriority(1)

            Button {
                renamingWorkspace = RenameWorkspaceRequest(
                    worktree: wt,
                    initialName: title
                )
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Rename workspace")

            Button {
                deletingWorkspace = DeleteWorkspaceRequest(
                    project: project,
                    worktree: wt,
                    displayName: title
                )
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Delete workspace")
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(NSColor.controlAccentColor).opacity(0.14))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(
                    isSelected
                    ? Color(NSColor.controlAccentColor).opacity(0.30)
                    : Color.clear,
                    lineWidth: 1
                )
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Rename Workspace…") {
                renamingWorkspace = RenameWorkspaceRequest(
                    worktree: wt,
                    initialName: title
                )
            }
            Button("Delete Workspace…") {
                deletingWorkspace = DeleteWorkspaceRequest(
                    project: project,
                    worktree: wt,
                    displayName: title
                )
            }
            Button("Open in New Tab") {
                model.selectWorktree(wt)
                openWorktree(wt.path, "")
            }
            ForEach(agentLaunchers) { launcher in
                Button("Open \(launcher.title) in YOLO Mode") {
                    model.selectWorktree(wt)
                    openWorktree(wt.path, "exec \(launcher.command)")
                }
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(wt.path, forType: .string)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: wt.path)]
                )
            }
        }
    }

    private var agentLaunchers: [AgentLauncher] {
        [
            AgentLauncher(
                title: "codex",
                systemImage: "sparkles",
                command: "codex --dangerously-bypass-approvals-and-sandbox"
            ),
            AgentLauncher(
                title: "claude",
                systemImage: "sun.max",
                command: "claude --dangerously-skip-permissions"
            ),
        ]
    }
}

private struct AgentLauncher: Identifiable {
    var title: String
    var systemImage: String
    var command: String

    var id: String { title }
}

private struct RenameWorkspaceRequest: Identifiable {
    var worktree: GitWorktree
    var initialName: String

    var id: String { worktree.path }
}

private struct DeleteWorkspaceRequest: Identifiable {
    var project: SidebarProject
    var worktree: GitWorktree
    var displayName: String

    var id: String { worktree.path }
}

private struct RenameWorkspaceSheet: View {
    let worktree: GitWorktree
    let initialName: String
    @ObservedObject var model: SidebarViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var name: String

    init(worktree: GitWorktree, initialName: String, model: SidebarViewModel) {
        self.worktree = worktree
        self.initialName = initialName
        self.model = model
        self._name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Workspace")
                .font(.headline)

            Form {
                TextField("Workspace name", text: $name)
                Text(worktree.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    model.renameWorkspace(for: worktree, to: name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 420)
    }
}

private struct DeleteWorkspaceSheet: View {
    let project: SidebarProject
    let worktree: GitWorktree
    let displayName: String
    @ObservedObject var model: SidebarViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var deleteLocalBranch: Bool = false
    @State private var submitting: Bool = false
    @State private var errorMessage: String?

    private var canDeleteLocalBranch: Bool {
        worktree.branch?.isEmpty == false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Delete Workspace")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text(displayName)
                    .font(.system(size: 13, weight: .semibold))
                Text(worktree.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Toggle("Delete local branch \(branchLabel)", isOn: $deleteLocalBranch)
                .disabled(!canDeleteLocalBranch || submitting)
                .onAppear {
                    if !canDeleteLocalBranch {
                        deleteLocalBranch = false
                    }
                }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(submitting)
                Button(submitting ? "Deleting…" : "Delete") {
                    deleteWorkspace()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(submitting)
            }
        }
        .padding(16)
        .frame(minWidth: 440)
    }

    private var branchLabel: String {
        guard let branch = worktree.branch, !branch.isEmpty else {
            return ""
        }
        return "(\(branch))"
    }

    private func deleteWorkspace() {
        submitting = true
        errorMessage = nil
        let shouldDeleteBranch = deleteLocalBranch && canDeleteLocalBranch

        Task {
            let result = await model.deleteWorkspace(
                worktree,
                in: project,
                deleteLocalBranch: shouldDeleteBranch
            )
            await MainActor.run {
                submitting = false
                switch result {
                case .success:
                    dismiss()
                case let .failure(error):
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
