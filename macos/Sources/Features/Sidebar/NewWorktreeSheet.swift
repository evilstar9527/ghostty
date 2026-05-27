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
    @State private var loadingRefs: Bool = true
    @State private var submitting: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Workspace — \(project.name)")
                .font(.headline)

            Form {
                TextField("Workspace name", text: $workspaceName)
                    .onChange(of: workspaceName) { _ in autofillPathIfNeeded() }

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
                    TextField("New branch name", text: $newBranchName)
                        .onChange(of: newBranchName) { _ in autofillPathIfNeeded() }

                    Toggle("Create new branch (-b)", isOn: $createBranch)

                    HStack {
                        Text("Base ref")
                        if loadingRefs {
                            ProgressView().controlSize(.small)
                            Spacer()
                        } else {
                            Picker("", selection: $ref) {
                                Text("HEAD").tag("HEAD")
                                ForEach(availableRefs, id: \.self) { r in
                                    Text(r).tag(r)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                }

                HStack {
                    TextField("Worktree path", text: pathBinding)
                        .disabled(useCurrentFolder)
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
        let name = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? newBranchName
            : workspaceName
        let safeName = sanitizePathComponent(name.isEmpty ? "branch" : name)
        return ((project.rootPath as NSString).appendingPathComponent(".worktree") as NSString)
            .appendingPathComponent(safeName)
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
