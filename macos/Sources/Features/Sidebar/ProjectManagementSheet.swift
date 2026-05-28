import SwiftUI
import AppKit

/// Sheet for adding/editing the user's project list.
struct ProjectManagementSheet: View {
    @ObservedObject var model: SidebarViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var newName: String = ""
    @State private var newPath: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Projects")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Close")
                .keyboardShortcut(.cancelAction)
            }

            List {
                ForEach(model.projects) { project in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(project.name).bold()
                            Text(project.rootPath)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            model.removeProject(project)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .frame(minHeight: 160)

            Divider()

            Text("Add a Project").font(.subheadline).bold()
            HStack {
                TextField("Display name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                TextField("Repository path", text: $newPath)
                    .textFieldStyle(.roundedBorder)
                Button("Browse…") { pickPath() }
                Button("Add") { addProject() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAddProject)
            }
        }
        .padding(16)
        .frame(minWidth: 540, minHeight: 340)
    }

    private var canAddProject: Bool {
        !newName.isEmpty && !newPath.isEmpty
    }

    private func pickPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            newPath = url.path
            if newName.isEmpty {
                newName = url.lastPathComponent
            }
        }
    }

    private func addProject() {
        model.addProject(name: newName, rootPath: newPath)
        newName = ""
        newPath = ""
    }
}
