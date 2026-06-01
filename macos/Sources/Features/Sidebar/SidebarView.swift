import AppKit
import SwiftUI

/// The worktree sidebar. Shows a list of user-configured projects, each
/// expandable to its `git worktree list` output. Clicking "Open" on a row
/// fires a tab-open notification with the worktree path as the cwd.
struct WorktreeSidebarView: View {
    @ObservedObject private var model = SidebarViewModel.shared

    /// Invoked with the absolute path of a worktree to open in a new tab.
    var openWorktree: (String, String?) -> Void
    var toggleSidebar: () -> Void

    @State private var showingProjectSheet: Bool = false
    @State private var newWorktreeFor: SidebarProject?
    @State private var renamingWorkspace: RenameWorkspaceRequest?
    @State private var deletingWorkspace: DeleteWorkspaceRequest?
    @State private var dragSession: SidebarDragSession?

    private let projectDragRowHeight: CGFloat = 24
    private let worktreeDragRowHeight: CGFloat = 44

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
            Button(action: toggleSidebar) {
                Image(systemName: "sidebar.leading")
            }
            .buttonStyle(.borderless)
            .help("Hide sidebar (⌘B)")

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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.projects) { project in
                        projectInsertionLine(before: project)
                        projectSection(project)
                        projectInsertionLine(after: project)
                    }

                    Color.clear
                        .frame(height: 10)
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func projectSection(_ project: SidebarProject) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            projectHeader(project)
            if model.expanded.contains(project.id) {
                projectWorktrees(project)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func projectHeader(_ project: SidebarProject) -> some View {
        let isExpanded = model.expanded.contains(project.id)
        let isDragging = dragSession?.isDraggingProject(project.id) == true

        return HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 12)

                Text(project.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay {
                SidebarMouseDragArea(
                    onClick: {
                        model.toggleExpanded(project)
                    },
                    onDragStart: {
                        guard let index = model.projects.firstIndex(where: { $0.id == project.id }) else {
                            return nil
                        }
                        let context = ProjectDragContext(id: project.id, startIndex: index)
                        dragSession = .project(context, targetIndex: index)
                        return context
                    },
                    onDragChanged: { deltaY, context in
                        updateDraggingProject(context, deltaY: deltaY)
                    },
                    onDragEnded: {
                        commitDragSession()
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Button {
                model.removeProject(project)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Remove project")
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isDragging {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(NSColor.controlAccentColor).opacity(0.18))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(
                    isDragging
                    ? Color(NSColor.controlAccentColor).opacity(0.45)
                    : Color.clear,
                    lineWidth: 1
                )
        }
    }

    @ViewBuilder
    private func projectWorktrees(_ project: SidebarProject) -> some View {
        if model.loading.contains(project.id) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading…")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            .padding(.leading, 58)
            .padding(.vertical, 6)
        } else if let worktrees = model.worktrees[project.id], !worktrees.isEmpty {
            worktreeRows(worktrees, project: project)
        } else {
            Text("No workspaces yet")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, 58)
                .padding(.vertical, 6)
        }

        Button {
            newWorktreeFor = project
        } label: {
            Label("New Worktree…", systemImage: "plus")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .padding(.leading, 58)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func worktreeRows(_ worktrees: [GitWorktree], project: SidebarProject) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(worktrees) { wt in
                worktreeInsertionLine(before: wt, in: project)
                worktreeRow(wt, project: project)
                worktreeInsertionLine(after: wt, in: project)
            }

            Color.clear
                .frame(height: 8)
        }
        .padding(.leading, 52)
    }

    private func worktreeRow(_ wt: GitWorktree, project: SidebarProject) -> some View {
        let title = model.displayName(for: wt)
        let subtitle = model.secondaryLabel(for: wt)
        let isSelected = model.isSelected(wt)
        let isDragging = dragSession?.isDraggingWorktree(wt.path, in: project.id) == true

        return HStack(alignment: .top, spacing: 8) {
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay {
                SidebarMouseDragArea(
                    onClick: {
                        model.selectWorktree(wt)
                        openWorktree(wt.path, nil)
                    },
                    onDragStart: {
                        guard let index = model.worktrees[project.id]?.firstIndex(where: { $0.path == wt.path }) else {
                            return nil
                        }
                        let context = WorktreeDragContext(
                            projectID: project.id,
                            path: wt.path,
                            startIndex: index
                        )
                        dragSession = .worktree(context, targetIndex: index)
                        return context
                    },
                    onDragChanged: { deltaY, context in
                        updateDraggingWorktree(context, in: project, deltaY: deltaY)
                    },
                    onDragEnded: {
                        commitDragSession()
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
            if isDragging {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(NSColor.controlAccentColor).opacity(0.22))
            } else if isSelected {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(NSColor.controlAccentColor).opacity(0.14))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(
                    isDragging
                    ? Color(NSColor.controlAccentColor).opacity(0.55)
                    : isSelected
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
                    openWorktree(wt.path, launcher.command)
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

    @ViewBuilder
    private func projectInsertionLine(before project: SidebarProject) -> some View {
        if shouldShowProjectInsertionLine(for: project, edge: .before) {
            SidebarInsertionLine()
                .padding(.horizontal, 10)
        }
    }

    @ViewBuilder
    private func projectInsertionLine(after project: SidebarProject) -> some View {
        if shouldShowProjectInsertionLine(for: project, edge: .after) {
            SidebarInsertionLine()
                .padding(.horizontal, 10)
        }
    }

    @ViewBuilder
    private func worktreeInsertionLine(
        before worktree: GitWorktree,
        in project: SidebarProject
    ) -> some View {
        if shouldShowWorktreeInsertionLine(for: worktree, in: project, edge: .before) {
            SidebarInsertionLine()
                .padding(.leading, 8)
                .padding(.trailing, 8)
        }
    }

    @ViewBuilder
    private func worktreeInsertionLine(
        after worktree: GitWorktree,
        in project: SidebarProject
    ) -> some View {
        if shouldShowWorktreeInsertionLine(for: worktree, in: project, edge: .after) {
            SidebarInsertionLine()
                .padding(.leading, 8)
                .padding(.trailing, 8)
        }
    }

    private func shouldShowProjectInsertionLine(
        for project: SidebarProject,
        edge: InsertionEdge
    ) -> Bool {
        guard case let .project(context, targetIndex) = dragSession,
              targetIndex != context.startIndex,
              let rowIndex = model.projects.firstIndex(where: { $0.id == project.id }) else {
            return false
        }

        switch edge {
        case .before:
            return targetIndex < context.startIndex && rowIndex == targetIndex
        case .after:
            return targetIndex > context.startIndex && rowIndex == targetIndex
        }
    }

    private func shouldShowWorktreeInsertionLine(
        for worktree: GitWorktree,
        in project: SidebarProject,
        edge: InsertionEdge
    ) -> Bool {
        guard case let .worktree(context, targetIndex) = dragSession,
              context.projectID == project.id,
              targetIndex != context.startIndex,
              let rowIndex = model.worktrees[project.id]?.firstIndex(where: { $0.path == worktree.path }) else {
            return false
        }

        switch edge {
        case .before:
            return targetIndex < context.startIndex && rowIndex == targetIndex
        case .after:
            return targetIndex > context.startIndex && rowIndex == targetIndex
        }
    }

    private func updateDraggingProject(_ context: Any?, deltaY: CGFloat) {
        guard let context = context as? ProjectDragContext,
              !model.projects.isEmpty else {
            return
        }

        let offset = Int((deltaY / projectDragRowHeight).rounded())
        let targetIndex = clampedIndex(context.startIndex - offset, upperBound: model.projects.count)
        dragSession = .project(context, targetIndex: targetIndex)
    }

    private func updateDraggingWorktree(_ context: Any?, in project: SidebarProject, deltaY: CGFloat) {
        guard let context = context as? WorktreeDragContext,
              context.projectID == project.id,
              let worktrees = model.worktrees[project.id],
              !worktrees.isEmpty else {
            return
        }

        let offset = Int((deltaY / worktreeDragRowHeight).rounded())
        let targetIndex = clampedIndex(context.startIndex - offset, upperBound: worktrees.count)
        dragSession = .worktree(context, targetIndex: targetIndex)
    }

    private func commitDragSession() {
        defer { dragSession = nil }

        switch dragSession {
        case let .project(context, targetIndex):
            model.moveProject(context.id, toIndex: targetIndex)
        case let .worktree(context, targetIndex):
            guard let project = model.projects.first(where: { $0.id == context.projectID }) else {
                return
            }
            model.moveWorktree(path: context.path, in: project, toIndex: targetIndex)
        case nil:
            return
        }
    }

    private func clampedIndex(_ index: Int, upperBound: Int) -> Int {
        min(max(index, 0), max(upperBound - 1, 0))
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

private struct ProjectDragContext {
    let id: UUID
    let startIndex: Int
}

private struct WorktreeDragContext {
    let projectID: UUID
    let path: String
    let startIndex: Int
}

private enum SidebarDragSession {
    case project(ProjectDragContext, targetIndex: Int)
    case worktree(WorktreeDragContext, targetIndex: Int)

    func isDraggingProject(_ id: UUID) -> Bool {
        guard case let .project(context, _) = self else { return false }
        return context.id == id
    }

    func isDraggingWorktree(_ path: String, in projectID: UUID) -> Bool {
        guard case let .worktree(context, _) = self else { return false }
        return context.projectID == projectID && context.path == path
    }
}

private enum InsertionEdge {
    case before
    case after
}

private struct SidebarInsertionLine: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(NSColor.controlAccentColor))
                .frame(width: 5, height: 5)
            Rectangle()
                .fill(Color(NSColor.controlAccentColor))
                .frame(height: 2)
                .clipShape(Capsule())
        }
        .frame(height: 6)
        .transition(.opacity)
    }
}

private struct SidebarMouseDragArea: NSViewRepresentable {
    var onClick: () -> Void
    var onDragStart: () -> Any?
    var onDragChanged: (CGFloat, Any?) -> Void
    var onDragEnded: () -> Void

    func makeNSView(context: Context) -> MouseDragView {
        let view = MouseDragView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: MouseDragView, context: Context) {
        nsView.onClick = onClick
        nsView.onDragStart = onDragStart
        nsView.onDragChanged = onDragChanged
        nsView.onDragEnded = onDragEnded
    }

    final class MouseDragView: NSView {
        var onClick: () -> Void = {}
        var onDragStart: () -> Any? = { nil }
        var onDragChanged: (CGFloat, Any?) -> Void = { _, _ in }
        var onDragEnded: () -> Void = {}

        private var mouseDownLocation: NSPoint?
        private var dragContext: Any?
        private var isDragging = false
        private let dragThreshold: CGFloat = 4

        override var acceptsFirstResponder: Bool { true }
        override var isFlipped: Bool { false }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard !isHidden,
                  alphaValue > 0.01,
                  bounds.contains(point) else {
                return nil
            }
            return self
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            window.makeFirstResponder(self)
            mouseDownLocation = event.locationInWindow
            dragContext = nil
            isDragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let mouseDownLocation else { return }
            let deltaX = event.locationInWindow.x - mouseDownLocation.x
            let deltaY = event.locationInWindow.y - mouseDownLocation.y
            let distance = hypot(deltaX, deltaY)
            if !isDragging {
                guard distance >= dragThreshold else { return }
                isDragging = true
                dragContext = onDragStart()
            }

            onDragChanged(deltaY, dragContext)
        }

        override func mouseUp(with event: NSEvent) {
            defer {
                mouseDownLocation = nil
                dragContext = nil
                isDragging = false
            }

            if !isDragging {
                onClick()
            } else {
                onDragEnded()
            }
        }
    }
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
