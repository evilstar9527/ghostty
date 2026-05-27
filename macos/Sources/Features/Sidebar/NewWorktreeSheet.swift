import SwiftUI
import AppKit

/// Sheet that creates a workspace, either by registering the current project
/// folder or by running `git worktree add`.
struct NewWorktreeSheet: View {
    let project: SidebarProject
    @ObservedObject var model: SidebarViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var path: String = ""
    @State private var ref: String = "HEAD"
    @State private var useCurrentFolder: Bool = false
    @State private var createBranch: Bool = true
    @State private var workspaceName: String = ""
    @State private var newBranchName: String = ""
    @State private var pathWasEdited: Bool = false
    @State private var availableRefs: [String] = []
    @State private var refSearch: String = ""
    @State private var loadingRefs: Bool = true
    @State private var submitting: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Workspace — \(project.name)")
                .font(.headline)

            Form {
                PasteableTextField("Workspace name", text: $workspaceName, onChange: {
                    autofillPathIfNeeded()
                })

                Toggle("Use current folder", isOn: $useCurrentFolder)
                    .onChange(of: useCurrentFolder) { useCurrent in
                        if useCurrent {
                            createBranch = false
                            path = project.rootPath
                            pathWasEdited = true
                        } else {
                            pathWasEdited = false
                            autofillPathIfNeeded()
                        }
                    }

                if !useCurrentFolder {
                    PasteableTextField("New branch name", text: $newBranchName, onChange: {
                        autofillPathIfNeeded()
                    })

                    Toggle("Create new branch (-b)", isOn: $createBranch)

                    HStack(alignment: .firstTextBaseline) {
                        Text("Base ref")
                        if loadingRefs {
                            ProgressView().controlSize(.small)
                            Spacer()
                        } else {
                            SearchableRefPicker(
                                placeholder: "Search branches",
                                refs: availableRefs,
                                selection: $ref,
                                searchText: $refSearch
                            )
                        }
                    }
                }

                HStack {
                    PasteableTextField(
                        "Worktree path",
                        text: pathBinding,
                        isEnabled: !useCurrentFolder
                    )
                    Button("Browse…") { pickPath() }
                        .disabled(useCurrentFolder)
                }

                if let err = errorMessage {
                    Text(err)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(submitButtonTitle) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(16)
        .frame(minWidth: 520)
        .task { await loadRefs() }
        .onAppear { autofillPathIfNeeded() }
    }

    private var canSubmit: Bool {
        guard !submitting else { return false }
        guard !path.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if useCurrentFolder { return true }
        if createBranch {
            return !newBranchName.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return !ref.isEmpty
    }

    private var submitButtonTitle: String {
        if submitting {
            return useCurrentFolder ? "Adding…" : "Creating…"
        }
        return useCurrentFolder ? "Add" : "Create"
    }

    private func loadRefs() async {
        let root = project.rootPath
        let refs: [String] = (try? WorktreeService.refs(in: root)) ?? []
        await MainActor.run {
            self.availableRefs = refs
            self.loadingRefs = false
        }
    }

    private func autofillPathIfNeeded() {
        if useCurrentFolder {
            path = project.rootPath
            return
        }
        guard !pathWasEdited else { return }
        path = defaultWorktreePath()
    }

    private var pathBinding: Binding<String> {
        Binding(
            get: { path },
            set: { newValue in
                path = newValue
                pathWasEdited = true
            }
        )
    }

    private func defaultWorktreePath() -> String {
        let name = newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = sanitizeBranchPath(name.isEmpty ? "branch" : name)
        return ((project.rootPath as NSString).appendingPathComponent(".worktree") as NSString)
            .appendingPathComponent(safeName)
    }

    private func sanitizeBranchPath(_ value: String) -> String {
        let components = value
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { sanitizePathComponent(String($0)) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        return components.isEmpty ? "branch" : components.joined(separator: "/")
    }

    private func sanitizePathComponent(_ value: String) -> String {
        var result = ""
        var lastWasDash = false
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))

        for scalar in value.unicodeScalars {
            if allowed.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }

        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? "branch" : trimmed
    }

    private func pickPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
            pathWasEdited = true
        }
    }

    private func submit() {
        submitting = true
        errorMessage = nil
        let p = project
        let target = path
        let baseRef = ref
        let useCurrent = useCurrentFolder
        let mkBranch = createBranch
        let bName = newBranchName
        let wName = workspaceName
        Task {
            let result: Result<Void, Error>
            if useCurrent {
                result = await model.addExistingWorkspace(
                    in: p,
                    path: p.rootPath,
                    workspaceName: wName
                )
            } else {
                result = await model.createWorktree(
                    in: p,
                    path: target,
                    ref: baseRef,
                    createBranch: mkBranch,
                    newBranchName: mkBranch ? bName : nil,
                    workspaceName: wName
                )
            }
            await MainActor.run {
                submitting = false
                switch result {
                case .success:
                    dismiss()
                case let .failure(err):
                    errorMessage = err.localizedDescription
                }
            }
        }
    }
}

private struct SearchableRefPicker: NSViewRepresentable {
    var placeholder: String
    var refs: [String]
    @Binding var selection: String
    @Binding var searchText: String

    func makeNSView(context: Context) -> RefPickerControl {
        let control = RefPickerControl()
        control.coordinator = context.coordinator
        return control
    }

    func updateNSView(_ control: RefPickerControl, context: Context) {
        context.coordinator.parent = self
        control.placeholder = placeholder
        control.text = searchText.isEmpty ? selection : searchText
        control.reloadSuggestions()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject {
        var parent: SearchableRefPicker

        init(parent: SearchableRefPicker) {
            self.parent = parent
        }

        var items: [String] {
            let query = parent.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedQuery = query == parent.selection ? "" : query
            let refs = parent.refs.filter { ref in
                normalizedQuery.isEmpty || ref.localizedCaseInsensitiveContains(normalizedQuery)
            }
            if parent.selection != "HEAD",
               parent.refs.contains(parent.selection),
               !refs.contains(parent.selection) {
                return ["HEAD", parent.selection] + refs
            }
            return ["HEAD"] + refs
        }

        func searchChanged(_ value: String, control: RefPickerControl) {
            parent.searchText = value
            control.reloadSuggestions()
            control.showSuggestions()
        }

        func searchDidBeginEditing(control: RefPickerControl) {
            if parent.searchText.isEmpty {
                parent.searchText = parent.selection
                control.text = parent.selection
            }
            control.reloadSuggestions()
            control.showSuggestions()
        }

        func select(_ value: String, control: RefPickerControl) {
            parent.selection = value
            parent.searchText = value
            control.text = value
            control.closeSuggestions()
        }

        func searchDidEndEditing(_ value: String, control: RefPickerControl) {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                parent.selection = "HEAD"
                parent.searchText = "HEAD"
                control.text = "HEAD"
                return
            }

            if value == "HEAD" || parent.refs.contains(value) {
                parent.selection = value
                parent.searchText = value
            }
        }
    }

    final class RefPickerControl: NSView, NSTextFieldDelegate {
        weak var coordinator: Coordinator?

        private let textField = NSTextField()
        private let button = NSButton()
        private let popover = NSPopover()

        var placeholder: String {
            get { textField.placeholderString ?? "" }
            set { textField.placeholderString = newValue }
        }

        var text: String {
            get { textField.stringValue }
            set {
                if textField.stringValue != newValue {
                    textField.stringValue = newValue
                }
            }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setup()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setup()
        }

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: 28)
        }

        private func setup() {
            textField.delegate = self
            textField.isEditable = true
            textField.isSelectable = true
            textField.isBordered = true
            textField.isBezeled = true
            textField.bezelStyle = .roundedBezel
            textField.lineBreakMode = .byClipping
            if let cell = textField.cell as? NSTextFieldCell {
                cell.usesSingleLineMode = true
                cell.isScrollable = true
                cell.wraps = false
            }

            button.isBordered = false
            button.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Show branches")
            button.target = self
            button.action = #selector(showSuggestionsAction)
            button.imagePosition = .imageOnly
            button.contentTintColor = .secondaryLabelColor

            addSubview(textField)
            addSubview(button)
            textField.translatesAutoresizingMaskIntoConstraints = false
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: leadingAnchor),
                textField.trailingAnchor.constraint(equalTo: trailingAnchor),
                textField.topAnchor.constraint(equalTo: topAnchor),
                textField.bottomAnchor.constraint(equalTo: bottomAnchor),
                button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
                button.centerYAnchor.constraint(equalTo: centerYAnchor),
                button.widthAnchor.constraint(equalToConstant: 24),
                button.heightAnchor.constraint(equalToConstant: 22),
            ])

            popover.behavior = .semitransient
        }

        func reloadSuggestions() {
            guard let coordinator else { return }
            let rootView = RefSuggestionList(
                refs: coordinator.items,
                selected: coordinator.parent.selection,
                onSelect: { [weak self] ref in
                    guard let self else { return }
                    self.coordinator?.select(ref, control: self)
                }
            )
            popover.contentViewController = NSHostingController(rootView: rootView)
            popover.contentSize = NSSize(width: max(bounds.width, 240), height: min(CGFloat(coordinator.items.count) * 30, 220))
        }

        func showSuggestions() {
            guard !popover.isShown else { return }
            reloadSuggestions()
            popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        }

        func closeSuggestions() {
            popover.close()
        }

        @objc private func showSuggestionsAction() {
            window?.makeFirstResponder(textField)
            showSuggestions()
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            textField.currentEditor()?.selectAll(nil)
            coordinator?.searchDidBeginEditing(control: self)
        }

        func controlTextDidChange(_ notification: Notification) {
            coordinator?.searchChanged(textField.stringValue, control: self)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            coordinator?.searchDidEndEditing(textField.stringValue, control: self)
        }
    }
}

private struct RefSuggestionList: View {
    let refs: [String]
    let selected: String
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(refs, id: \.self) { ref in
                    Button {
                        onSelect(ref)
                    } label: {
                        HStack {
                            Text(ref)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(ref == selected ? Color.accentColor.opacity(0.16) : Color.clear)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct PasteableTextField: NSViewRepresentable {
    var placeholder: String
    @Binding var text: String
    var isEnabled: Bool
    var selectAllOnFocus: Bool
    var onChange: () -> Void
    var onBeginEditing: () -> Void

    init(
        _ placeholder: String,
        text: Binding<String>,
        isEnabled: Bool = true,
        selectAllOnFocus: Bool = false,
        onChange: @escaping () -> Void = {},
        onBeginEditing: @escaping () -> Void = {}
    ) {
        self.placeholder = placeholder
        self._text = text
        self.isEnabled = isEnabled
        self.selectAllOnFocus = selectAllOnFocus
        self.onChange = onChange
        self.onBeginEditing = onBeginEditing
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.delegate = context.coordinator
        textField.placeholderString = placeholder
        textField.isEditable = true
        textField.isSelectable = true
        textField.isBordered = true
        textField.isBezeled = true
        textField.bezelStyle = .roundedBezel
        textField.lineBreakMode = .byClipping
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let cell = textField.cell as? NSTextFieldCell {
            cell.usesSingleLineMode = true
            cell.isScrollable = true
            cell.wraps = false
        }
        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        context.coordinator.parent = self
        if textField.stringValue != text {
            textField.stringValue = text
        }
        textField.placeholderString = placeholder
        textField.isEnabled = isEnabled
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PasteableTextField

        init(parent: PasteableTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            parent.text = textField.stringValue
            parent.onChange()
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            parent.onBeginEditing()
            if parent.selectAllOnFocus {
                textField.currentEditor()?.selectAll(nil)
            }
        }
    }
}
