import SwiftUI
import AppKit

/// The Agent-mode project picker, sitting next to the model picker in the
/// chat top bar.
///
/// A project is a folder (usually a codebase) the agent works inside:
/// selecting one scopes every tool in the run to that folder and loads the
/// project's own memory into the agent's context. From here the user can
/// switch projects, run with no project, add a new project folder, or jump
/// to Settings → Projects to edit names, notes, instructions, and memory.
struct AgentProjectPickerView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var projectsStore = AgentProjectsStore.shared

    /// Matches the model pill's styling context (dark hero vs. normal).
    var isEmptyConversation: Bool = false

    private var selectedName: String {
        projectsStore.selectedProject?.name ?? "No Project"
    }

    var body: some View {
        Menu {
            Section("Project for this agent") {
                Button {
                    projectsStore.select(nil)
                } label: {
                    HStack {
                        Text("No Project")
                        if projectsStore.selectedProjectID == nil {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                ForEach(projectsStore.projects) { project in
                    Button {
                        projectsStore.select(project.id)
                    } label: {
                        HStack {
                            Text(project.name)
                            if !project.folderExists {
                                Text("(folder missing)")
                            }
                            if project.id == projectsStore.selectedProjectID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            Divider()

            Button("Add Project…", systemImage: "folder.badge.plus") {
                addProjectFromFolderPicker()
            }

            Button("Manage Projects…", systemImage: "folder.gearshape") {
                openWindow(id: "settings")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.cyan)
                Text(selectedName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isEmptyConversation ? .white : .primary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(isEmptyConversation ? .white.opacity(0.8) : .secondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                isEmptyConversation
                    ? Color.black.opacity(0.2)
                    : Color.cyan.opacity(0.10),
                in: .capsule
            )
            .overlay(
                Capsule()
                    .stroke(Color.cyan.opacity(0.30), lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(projectsStore.selectedProject.map { "Agent project: \($0.name) — \($0.rootPath)" } ?? "Choose a project folder for the agent to work in")
    }

    private func addProjectFromFolderPicker() {
        let panel = NSOpenPanel()
        panel.title = "Choose Project Folder"
        panel.prompt = "Add Project"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            projectsStore.addProject(rootURL: url)
        }
    }
}
