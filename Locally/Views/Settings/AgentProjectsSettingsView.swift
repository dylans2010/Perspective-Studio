import SwiftUI
import AppKit

/// Settings → Projects: full control over Agent Projects.
///
/// A project is a folder (usually a codebase) the agent works inside in
/// Agent mode. Here the user can add projects, rename them, re-point them
/// at a different folder, remove them, edit their notes and standing
/// instructions, and manage the per-project memory the agent reads at the
/// start of every run and writes back to as it learns.
struct AgentProjectsSettingsView: View {
    @State private var store = AgentProjectsStore.shared
    @State private var editingProjectID: UUID?
    @State private var draftName: String = ""
    @State private var draftNotes: String = ""
    @State private var draftInstructions: String = ""
    @State private var newMemoryText: String = ""
    @State private var newMemoryKind: AgentProjectMemoryEntry.Kind = .fact

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Projects")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    addProject()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.badge.plus")
                        Text("Add Project…")
                    }
                    .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Text("Projects give the agent a home folder — usually a codebase. When a project is selected in Agent mode, the agent works inside that folder, follows the project's instructions, and builds on its own per-project memory of what it has learned there.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            if store.projects.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                    Text("No projects yet. Add a folder to get started.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
                .liquidGlass(.rect(cornerRadius: 14))
            } else {
                ForEach(store.projects) { project in
                    projectCard(project)
                }
            }

            agentEngineCard
        }
        .onAppear {
            if editingProjectID == nil, let first = store.projects.first {
                beginEditing(first)
            }
        }
    }

    // MARK: - Project Card

    private func projectCard(_ project: AgentProject) -> some View {
        let isEditing = editingProjectID == project.id
        let isSelected = store.selectedProjectID == project.id

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                    Text(project.rootPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(project.folderExists ? Color.secondary : Color.red)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !project.folderExists {
                        Text("This folder no longer exists — re-point the project or remove it.")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                }
                Spacer()
                if isSelected {
                    Text("Active in Agent mode")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.cyan)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.cyan.opacity(0.12), in: .capsule)
                } else {
                    Button("Use in Agent Mode") {
                        store.select(project.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button(isEditing ? "Done" : "Edit") {
                    if isEditing {
                        saveDraft(to: project)
                        editingProjectID = nil
                    } else {
                        beginEditing(project)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if isEditing {
                editFields(project)
            }

            memorySection(project)

            HStack {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([project.rootURL])
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                Spacer()
                Button("Remove Project", role: .destructive) {
                    if editingProjectID == project.id { editingProjectID = nil }
                    store.removeProject(id: project.id)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.red)
                .help("Removes the project and its memory from Locally. The folder on disk is not touched.")
            }
        }
        .padding(16)
        .liquidGlass(.rect(cornerRadius: 14))
    }

    private func editFields(_ project: AgentProject) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Name") {
                TextField("Project name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
            }
            LabeledContent("Folder") {
                HStack {
                    Text(project.rootPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Change…") { changeFolder(for: project) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Notes — what this project is")
                    .font(.system(size: 12, weight: .semibold))
                TextEditor(text: $draftNotes)
                    .font(.system(size: 12))
                    .frame(minHeight: 44)
                    .padding(6)
                    .background(Color(.controlBackgroundColor))
                    .clipShape(.rect(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Instructions — how the agent should work in this project")
                    .font(.system(size: 12, weight: .semibold))
                TextEditor(text: $draftInstructions)
                    .font(.system(size: 12))
                    .frame(minHeight: 44)
                    .padding(6)
                    .background(Color(.controlBackgroundColor))
                    .clipShape(.rect(cornerRadius: 8))
            }
            HStack {
                Spacer()
                Button("Save Changes") {
                    saveDraft(to: project)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Memory Section

    private func memorySection(_ project: AgentProject) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Project Memory")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                Text("\(project.memory.count) entr\(project.memory.count == 1 ? "y" : "ies")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if !project.memory.isEmpty {
                    Button("Clear All") {
                        store.clearMemory(projectID: project.id)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                }
            }
            Text("The agent reads this memory at the start of every run in this project, adds a session note after each run, and can record new facts itself while it works. Nothing here is shared with other projects.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if !project.memory.isEmpty {
                VStack(spacing: 0) {
                    ForEach(project.memoryNewestFirst) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(entry.kind.label)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.cyan)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.cyan.opacity(0.12), in: .capsule)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.text)
                                    .font(.system(size: 12))
                                Text(entry.createdAt, format: .dateTime.month().day().hour().minute())
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button {
                                store.removeMemoryEntry(projectID: project.id, entryID: entry.id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Forget this entry")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        if entry.id != project.memoryNewestFirst.last?.id {
                            Divider()
                        }
                    }
                }
                .background(Color.white.opacity(0.04), in: .rect(cornerRadius: 10))
            }

            HStack(spacing: 8) {
                Picker("Kind", selection: $newMemoryKind) {
                    ForEach([AgentProjectMemoryEntry.Kind.fact, .instruction], id: \.self) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 120)
                TextField("Add a fact or instruction for this project…", text: $newMemoryText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addMemory(to: project) }
                Button("Add") { addMemory(to: project) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: - Agent Engine (bundled Antigravity SDK)

    private var agentEngineCard: some View {
        let status = AntigravitySDKBundle.status()
        return VStack(alignment: .leading, spacing: 8) {
            Text("Agent Engine")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
            HStack(spacing: 8) {
                Image(systemName: status.isUsable ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(status.isUsable ? .green : .orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(status.summary)
                        .font(.system(size: 12, weight: .semibold))
                    Text("The SDK provides the agent loop only. Models are your local models and tools are Locally's — the SDK ships with no models and no tools of its own.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if !status.issues.isEmpty {
                        Text(status.issues.joined(separator: " "))
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(16)
        .liquidGlass(.rect(cornerRadius: 14))
    }

    // MARK: - Actions

    private func beginEditing(_ project: AgentProject) {
        editingProjectID = project.id
        draftName = project.name
        draftNotes = project.notes
        draftInstructions = project.instructions
    }

    private func saveDraft(to project: AgentProject) {
        var updated = project
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { updated.name = name }
        updated.notes = draftNotes
        updated.instructions = draftInstructions
        store.updateProject(updated)
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.title = "Choose Project Folder"
        panel.prompt = "Add Project"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            let project = store.addProject(rootURL: url)
            beginEditing(project)
        }
    }

    private func changeFolder(for project: AgentProject) {
        let panel = NSOpenPanel()
        panel.title = "Choose New Folder for \(project.name)"
        panel.prompt = "Use Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = project.rootURL
        if panel.runModal() == .OK, let url = panel.url {
            var updated = project
            updated.rootPath = url.standardizedFileURL.path
            store.updateProject(updated)
        }
    }

    private func addMemory(to project: AgentProject) {
        let text = newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.addMemoryEntry(projectID: project.id, text: text, kind: newMemoryKind)
        newMemoryText = ""
    }
}
