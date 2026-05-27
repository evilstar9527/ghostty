import SwiftUI
import GhosttyKit
import os

/// This delegate is notified of actions and property changes regarding the terminal view. This
/// delegate is optional and can be used by a TerminalView caller to react to changes such as
/// titles being set, cell sizes being changed, etc.
protocol TerminalViewDelegate: AnyObject {
    /// Called when the currently focused surface changed. This can be nil.
    func focusedSurfaceDidChange(to: Ghostty.SurfaceView?)

    /// The URL of the pwd should change.
    func pwdDidChange(to: URL?)

    /// The cell size changed.
    func cellSizeDidChange(to: NSSize)

    /// Perform an action. At the time of writing this is only triggered by the command palette.
    func performAction(_ action: String, on: Ghostty.SurfaceView)

    /// A split tree operation
    func performSplitAction(_ action: TerminalSplitOperation)
}

/// The view model is a required implementation for TerminalView callers. This contains
/// the main state between the TerminalView caller and SwiftUI. This abstraction is what
/// allows AppKit to own most of the data in SwiftUI.
protocol TerminalViewModel: ObservableObject {
    /// The tree of terminal surfaces (splits) within the view. This is mutated by TerminalView
    /// and children. This should be @Published.
    var surfaceTree: SplitTree<Ghostty.SurfaceView> { get set }

    /// The command palette state.
    var commandPaletteIsShowing: Bool { get set }

    /// The update overlay should be visible.
    var updateOverlayIsVisible: Bool { get }

    /// Whether the worktree sidebar is shown for this terminal window.
    var sidebarVisible: Bool { get set }

    /// Fractional width of the sidebar relative to the window content (0..1).
    var sidebarSplit: CGFloat { get set }

    /// Whether this view model supports the worktree sidebar. Window types
    /// that should never show the sidebar (Quick Terminal) return false.
    var sidebarSupported: Bool { get }

    /// Logical tabs for the currently selected worktree.
    var activeWorktreeTabs: [WorktreeTerminalTab] { get }

    /// The selected logical tab for the currently selected worktree.
    var activeWorktreeTabID: UUID? { get }

    /// The selected worktree path for this terminal window.
    var activeWorktreePath: String? { get }

    /// Selects an existing worktree tab group if it exists.
    func selectWorktree(path: String) -> Bool

    /// Opens a logical tab inside the current terminal window for a worktree.
    func openWorktreeTab(path: String, title: String, initialInput: String?)

    /// Selects a logical tab in the currently selected worktree.
    func selectWorktreeTab(id: UUID)

    /// Renames a logical tab in the currently selected worktree.
    func renameWorktreeTab(id: UUID, title: String)
}

extension TerminalViewModel {
    var sidebarVisible: Bool {
        get { false }
        set { _ = newValue }
    }
    var sidebarSplit: CGFloat {
        get { 0.22 }
        set { _ = newValue }
    }
    var sidebarSupported: Bool { false }

    func renameWorktreeTab(id: UUID, title: String) {}
}

struct WorktreeTerminalTab: Identifiable {
    let id: UUID
    var title: String
    var path: String
    var surfaceTree: SplitTree<Ghostty.SurfaceView>
    var agentName: String?
}

/// The main terminal view. This terminal view supports splits.
struct TerminalView<ViewModel: TerminalViewModel>: View {
    @ObservedObject var ghostty: Ghostty.App

    // The required view model
    @ObservedObject var viewModel: ViewModel

    // An optional delegate to receive information about terminal changes.
    weak var delegate: (any TerminalViewDelegate)?

    /// The most recently focused surface, equal to `focusedSurface` when it is non-nil.
    @State private var lastFocusedSurface: Weak<Ghostty.SurfaceView>?

    // This seems like a crutch after switching from SwiftUI to AppKit lifecycle.
    @FocusState private var focused: Bool

    // Various state values sent back up from the currently focused terminals.
    @FocusedValue(\.ghosttySurfaceView) private var focusedSurface
    @FocusedValue(\.ghosttySurfacePwd) private var surfacePwd
    @FocusedValue(\.ghosttySurfaceCellSize) private var cellSize

    // The pwd of the focused surface as a URL
    private var pwdURL: URL? {
        guard let surfacePwd, surfacePwd != "" else { return nil }
        return URL(fileURLWithPath: surfacePwd)
    }

    var body: some View {
        switch ghostty.readiness {
        case .loading:
            Text("Loading")
        case .error:
            ErrorView()
        case .ready:
            if viewModel.sidebarVisible {
                SplitView(
                    .horizontal,
                    Binding(
                        get: { viewModel.sidebarSplit },
                        set: { viewModel.sidebarSplit = $0 }
                    ),
                    dividerColor: ghostty.config.splitDividerColor,
                    left: {
                        WorktreeSidebarView(
                            openWorktree: { path, initialInput in
                                openWorktreeInNewTab(at: path, initialInput: initialInput)
                            },
                            toggleSidebar: { viewModel.sidebarVisible.toggle() }
                        )
                        .frame(minWidth: 200)
                    },
                    right: {
                        terminalArea
                    },
                    onEqualize: { viewModel.sidebarSplit = 0.22 }
                )
                .onChange(of: viewModel.sidebarVisible) { newValue in
                    if !newValue, let s = lastFocusedSurface?.value {
                        Ghostty.moveFocus(to: s)
                    }
                }
            } else {
                terminalAreaWithSidebarToggle
            }
        }
    }

    private func openWorktreeInNewTab(at path: String, initialInput: String?) {
        if initialInput == nil,
           viewModel.selectWorktree(path: path) {
            return
        }

        viewModel.openWorktreeTab(
            path: path,
            title: worktreeTabTitle(for: initialInput),
            initialInput: initialInput
        )
    }

    private func worktreeTabTitle(for initialInput: String?) -> String {
        guard let initialInput, !initialInput.isEmpty else { return "terminal" }
        if initialInput.contains("codex") { return "codex" }
        if initialInput.contains("claude") { return "claude" }
        return "terminal"
    }

    private var terminalArea: some View {
        VStack(spacing: 0) {
            if viewModel.activeWorktreePath != nil {
                WorktreeTabBar(
                    tabs: viewModel.activeWorktreeTabs,
                    selectedID: viewModel.activeWorktreeTabID,
                    themeBackground: ghostty.config.backgroundColor,
                    dividerColor: ghostty.config.splitDividerColor,
                    select: { viewModel.selectWorktreeTab(id: $0) },
                    openCodex: {
                        guard let path = viewModel.activeWorktreePath else { return }
                        viewModel.openWorktreeTab(
                            path: path,
                            title: "codex",
                            initialInput: "exec codex --dangerously-bypass-approvals-and-sandbox"
                        )
                    },
                    openClaude: {
                        guard let path = viewModel.activeWorktreePath else { return }
                        viewModel.openWorktreeTab(
                            path: path,
                            title: "claude",
                            initialInput: "exec claude --dangerously-skip-permissions"
                        )
                    },
                    openTerminal: {
                        guard let path = viewModel.activeWorktreePath else { return }
                        viewModel.openWorktreeTab(
                            path: path,
                            title: "terminal",
                            initialInput: nil
                        )
                    },
                    rename: { id, title in
                        viewModel.renameWorktreeTab(id: id, title: title)
                    }
                )
                Divider()
            }

            if viewModel.activeWorktreePath != nil {
                worktreeTabsBody
            } else {
                readyBody
            }
        }
    }

    private var terminalAreaWithSidebarToggle: some View {
        ZStack(alignment: .topLeading) {
            terminalArea

            Button {
                viewModel.sidebarVisible.toggle()
            } label: {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.secondary)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(ghostty.config.backgroundColor.opacity(0.86))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(ghostty.config.splitDividerColor.opacity(0.45), lineWidth: 1)
            }
            .padding(.leading, 8)
            .padding(.top, 6)
            .help("Show sidebar (⌘B)")
        }
    }

    private var worktreeTabsBody: some View {
        ZStack {
            ForEach(viewModel.activeWorktreeTabs) { tab in
                let isSelected = tab.id == viewModel.activeWorktreeTabID
                TerminalSplitTreeView(
                    tree: tab.surfaceTree,
                    action: { delegate?.performSplitAction($0) })
                    .environmentObject(ghostty)
                    .ghosttyLastFocusedSurface(lastFocusedSurface)
                    .focused($focused)
                    .opacity(isSelected ? 1 : 0)
                    .allowsHitTesting(isSelected)
                    .accessibilityHidden(!isSelected)
                    .zIndex(isSelected ? 1 : 0)
            }
            .onAppear { self.focused = true }
            .onChange(of: focusedSurface) { newValue in
                if newValue != nil {
                    lastFocusedSurface = .init(newValue)
                    self.delegate?.focusedSurfaceDidChange(to: newValue)
                }
            }
            .onChange(of: pwdURL) { newValue in
                self.delegate?.pwdDidChange(to: newValue)
            }
            .onChange(of: cellSize) { newValue in
                guard let size = newValue else { return }
                self.delegate?.cellSizeDidChange(to: size)
            }

            if let surfaceView = lastFocusedSurface?.value {
                TerminalCommandPaletteView(
                    surfaceView: surfaceView,
                    isPresented: $viewModel.commandPaletteIsShowing,
                    ghosttyConfig: ghostty.config,
                    updateViewModel: (NSApp.delegate as? AppDelegate)?.updateViewModel) { action in
                    self.delegate?.performAction(action, on: surfaceView)
                }
            }

            if viewModel.updateOverlayIsVisible {
                UpdateOverlay()
            }
        }
        .frame(maxWidth: .greatestFiniteMagnitude, maxHeight: .greatestFiniteMagnitude)
        .ignoresSafeArea(.container, edges: ghostty.config.macosTitlebarStyle == .hidden ? .top : [])
    }

    private var readyBody: some View {
        ZStack {
            VStack(spacing: 0) {
                TerminalSplitTreeView(
                    tree: viewModel.surfaceTree,
                    action: { delegate?.performSplitAction($0) })
                    .environmentObject(ghostty)
                    .ghosttyLastFocusedSurface(lastFocusedSurface)
                    .focused($focused)
                    .onAppear { self.focused = true }
                    .onChange(of: focusedSurface) { newValue in
                        // We want to keep track of our last focused surface so even if
                        // we lose focus we keep this set to the last non-nil value.
                        if newValue != nil {
                            lastFocusedSurface = .init(newValue)
                            self.delegate?.focusedSurfaceDidChange(to: newValue)
                        }
                    }
                    .onChange(of: pwdURL) { newValue in
                        self.delegate?.pwdDidChange(to: newValue)
                    }
                    .onChange(of: cellSize) { newValue in
                        guard let size = newValue else { return }
                        self.delegate?.cellSizeDidChange(to: size)
                    }
                    .frame(idealWidth: lastFocusedSurface?.value?.initialSize?.width,
                           idealHeight: lastFocusedSurface?.value?.initialSize?.height)
            }
            // Ignore safe area to extend up in to the titlebar region if we have the "hidden" titlebar style
            .ignoresSafeArea(.container, edges: ghostty.config.macosTitlebarStyle == .hidden ? .top : [])

            if let surfaceView = lastFocusedSurface?.value {
                TerminalCommandPaletteView(
                    surfaceView: surfaceView,
                    isPresented: $viewModel.commandPaletteIsShowing,
                    ghosttyConfig: ghostty.config,
                    updateViewModel: (NSApp.delegate as? AppDelegate)?.updateViewModel) { action in
                    self.delegate?.performAction(action, on: surfaceView)
                }
            }

            // Show update information above all else.
            if viewModel.updateOverlayIsVisible {
                UpdateOverlay()
            }
        }
        .frame(maxWidth: .greatestFiniteMagnitude, maxHeight: .greatestFiniteMagnitude)
    }
}

private struct WorktreeTabBar: View {
    let tabs: [WorktreeTerminalTab]
    let selectedID: UUID?
    let themeBackground: Color
    let dividerColor: Color
    let select: (UUID) -> Void
    let openCodex: () -> Void
    let openClaude: () -> Void
    let openTerminal: () -> Void
    let rename: (UUID, String) -> Void

    @State private var editingTabID: UUID?
    @State private var editingTitle: String = ""
    @FocusState private var focusedEditingTabID: UUID?

    var body: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tabs) { tab in
                        tabButton(tab)
                    }
                }
                .padding(.leading, 10)
            }
            .frame(minHeight: 32)

            Spacer(minLength: 6)

            HStack(spacing: 6) {
                actionButton("codex", systemImage: "sparkles", action: openCodex)
                    .help("Launch codex in YOLO mode")
                actionButton("claude", systemImage: "sun.max", action: openClaude)
                    .help("Launch claude in YOLO mode")
                actionButton("terminal", systemImage: "terminal", action: openTerminal)
                    .help("Open terminal tab")
            }
            .padding(3)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(themeBackground.opacity(0.58))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(dividerColor.opacity(0.42), lineWidth: 1)
                    }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            Rectangle()
                .fill(themeBackground.opacity(0.68))
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(dividerColor.opacity(0.45))
                        .frame(height: 1)
                }
        }
        .onChange(of: selectedID) { _ in
            commitEditing()
        }
    }

    @ViewBuilder
    private func tabButton(_ tab: WorktreeTerminalTab) -> some View {
        let isSelected = tab.id == selectedID

        if editingTabID == tab.id {
            tabContents(tab, isSelected: isSelected)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .background { tabBackground(isSelected: isSelected) }
                .overlay { tabBorder(isSelected: isSelected) }
        } else {
            Button {
                select(tab.id)
            } label: {
                tabContents(tab, isSelected: isSelected)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .background { tabBackground(isSelected: isSelected) }
                    .overlay { tabBorder(isSelected: isSelected) }
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                beginEditing(tab)
            })
            .contextMenu {
                Button("Rename Tab...") {
                    beginEditing(tab)
                }
            }
        }
    }

    private func tabContents(_ tab: WorktreeTerminalTab, isSelected: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: iconName(for: tab.title))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            tabTitle(tab, isSelected: isSelected)
        }
    }

    @ViewBuilder
    private func tabTitle(_ tab: WorktreeTerminalTab, isSelected: Bool) -> some View {
        if editingTabID == tab.id {
            TextField("", text: $editingTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .lineLimit(1)
                .frame(minWidth: 44, maxWidth: 140)
                .focused($focusedEditingTabID, equals: tab.id)
                .onSubmit { commitEditing() }
                .onExitCommand { cancelEditing() }
                .onDisappear { commitEditing() }
                .onAppear { focusedEditingTabID = tab.id }
        } else {
            Text(tab.title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .lineLimit(1)
        }
    }

    private func beginEditing(_ tab: WorktreeTerminalTab) {
        editingTabID = tab.id
        editingTitle = tab.title
        focusedEditingTabID = tab.id
    }

    private func commitEditing() {
        guard let editingTabID else { return }
        let title = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            rename(editingTabID, title)
        }
        self.editingTabID = nil
        editingTitle = ""
        focusedEditingTabID = nil
    }

    private func cancelEditing() {
        editingTabID = nil
        editingTitle = ""
        focusedEditingTabID = nil
    }

    private func tabBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(isSelected
                  ? themeBackground.opacity(0.76)
                  : Color.clear)
            .shadow(
                color: isSelected ? Color.black.opacity(0.06) : Color.clear,
                radius: 2,
                x: 0,
                y: 1
            )
    }

    private func tabBorder(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 7)
            .stroke(
                isSelected
                ? dividerColor.opacity(0.58)
                : Color.clear,
                lineWidth: 1
            )
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary.opacity(0.82))
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(themeBackground.opacity(0.66))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(dividerColor.opacity(0.46), lineWidth: 1)
        }
    }

    private func iconName(for title: String) -> String {
        if title.contains("codex") { return "sparkles" }
        if title.contains("claude") { return "sun.max" }
        return "terminal"
    }
}

private struct UpdateOverlay: View {
    var body: some View {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            VStack {
                Spacer()

                HStack {
                    Spacer()
                    UpdatePill(model: appDelegate.updateViewModel)
                        .padding(.bottom, 9)
                        .padding(.trailing, 9)
                }
            }
        }
    }
}

struct DebugBuildWarningView: View {
    @State private var isPopover = false

    var body: some View {
        HStack {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)

            Text("You're running a debug build of Ghostty! Performance will be degraded.")
                .padding(.all, 8)
                .popover(isPresented: $isPopover, arrowEdge: .bottom) {
                    Text("""
                    Debug builds of Ghostty are very slow and you may experience
                    performance problems. Debug builds are only recommended during
                    development.
                    """)
                    .padding(.all)
                }

            Spacer()
        }
        .background(Color(.windowBackgroundColor))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Debug build warning")
        .accessibilityValue("Debug builds of Ghostty are very slow and you may experience performance problems. Debug builds are only recommended during development.")
        .accessibilityAddTraits(.isStaticText)
        .onTapGesture {
            isPopover = true
        }
    }
}
