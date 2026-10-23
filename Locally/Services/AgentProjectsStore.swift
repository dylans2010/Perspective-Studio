import Foundation
import Observation

/// Owns Agent Projects: the user's named folders (codebases) for Agent
/// mode, which one is selected, and each project's persistent memory.
///
/// Persistence follows the app's established pattern for app-level
/// libraries: a versioned JSON envelope in Application Support via
/// `JSONFileStore` (`agent-projects.json`), separate from the SwiftData
/// chat store. The selection is kept alongside the projects so it survives
/// relaunch and is shared by the chat picker, Settings, and the agent
/// runtime.
@Observable
@MainActor
public final class AgentProjectsStore {
    public static let shared = AgentProjectsStore()

    public private(set) var projects: [AgentProject] = []
    public var selectedProjectID: UUID? {
        didSet { persist() }
    }

    private static let filename = "agent-projects.json"

    /// The envelope persisted to disk: projects plus the selection, one
    /// file so the two can never disagree.
    private nonisolated struct PersistedState: Codable, Sendable {
        var projects: [AgentProject]
        var selectedProjectID: UUID?
    }

    public init() {
        if let state = JSONFileStore.load(PersistedState.self, filename: Self.filename) {
            self.projects = state.projects
            self.selectedProjectID = state.selectedProjectID
        }
    }

    // MARK: - Selection

    public var selectedProject: AgentProject? {
        guard let selectedProjectID else { return nil }
        return projects.first { $0.id == selectedProjectID }
    }

    /// The selected project when it can actually scope a run (it exists and
    /// its folder is still there). A missing folder degrades the run to the
    /// default workspace instead of failing it.
    public var activeProject: AgentProject? {
        guard let project = selectedProject, project.folderExists else { return nil }
        return project
    }

    public func select(_ projectID: UUID?) {
        selectedProjectID = projectID
    }

    // MARK: - CRUD (Settings)

    /// Adds a project for a folder the user picked. The name defaults to
    /// the folder's last path component and can be edited in Settings.
    /// Re-adding an already-registered folder selects it instead of
    /// creating a duplicate.
    @discardableResult
    public func addProject(rootURL: URL, name: String? = nil) -> AgentProject {
        let standardized = rootURL.standardizedFileURL
        if let existing = projects.first(where: { URL(fileURLWithPath: $0.rootPath).standardizedFileURL == standardized }) {
            selectedProjectID = existing.id
            return existing
        }
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = AgentProject(
            name: (trimmedName?.isEmpty == false ? trimmedName! : standardized.lastPathComponent),
            rootPath: standardized.path
        )
        projects.append(project)
        selectedProjectID = project.id
        persist()
        return project
    }

    public func updateProject(_ project: AgentProject) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        var updated = project
        updated.updatedAt = .now
        projects[index] = updated
        persist()
    }

    /// Removes the project and its memory. The folder on disk is untouched.
    public func removeProject(id: UUID) {
        projects.removeAll { $0.id == id }
        if selectedProjectID == id {
            selectedProjectID = nil
        }
        persist()
    }

    public func project(id: UUID) -> AgentProject? {
        projects.first { $0.id == id }
    }

    // MARK: - Per-project memory

    /// Records one memory entry for a project. Used by the Settings editor,
    /// the project memory tool (agent-written facts), and the automatic
    /// post-run session note. Identical consecutive session notes are
    /// coalesced so repeated runs don't flood the memory.
    public func addMemoryEntry(projectID: UUID, text: String, kind: AgentProjectMemoryEntry.Kind) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = projects.firstIndex(where: { $0.id == projectID }) else { return }

        if kind == .session, projects[index].memoryNewestFirst.first?.text == trimmed {
            return
        }
        projects[index].memory.append(AgentProjectMemoryEntry(text: trimmed, kind: kind))
        projects[index].updatedAt = .now
        persist()
    }

    public func removeMemoryEntry(projectID: UUID, entryID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].memory.removeAll { $0.id == entryID }
        projects[index].updatedAt = .now
        persist()
    }

    public func clearMemory(projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].memory.removeAll()
        projects[index].updatedAt = .now
        persist()
    }

    // MARK: - Agent context

    /// The prompt block for one agent run in a project: identity, folder,
    /// the user's notes and standing instructions, and the project's
    /// memory — plus the rules for using that memory. This is what makes
    /// the agent *remember this project in particular*: memory is injected
    /// on every run, and durable new facts are written back through the
    /// project memory tool and the post-run session note.
    public func contextBlock(for project: AgentProject, memoryLimit: Int = 40) -> String {
        var lines: [String] = [
            "[Active Project — \(project.name)]",
            "Project folder (your workspace root for this run — resolve every relative path against it, and stay inside it unless the user says otherwise): \(project.rootPath)"
        ]
        if !project.folderExists {
            lines.append("WARNING: this project's folder does not currently exist at that path. Tell the user, and do not invent its contents.")
        }
        let notes = project.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            lines.append("About this project: \(notes)")
        }
        let instructions = project.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instructions.isEmpty {
            lines.append("Standing instructions for this project (follow them):\n\(instructions)")
        }

        // Orientation snapshot — kind, layout, branch, README — so the
        // first tool call can go at the task instead of rediscovering
        // the project's shape.
        let snapshot = AgentProjectSnapshot.contextBlock(for: project)
        if !snapshot.isEmpty {
            lines.append(snapshot)
        }

        // The project's own commands, when the user set them: verify
        // the way this project verifies.
        let buildCommand = project.buildCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let testCommand = project.testCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !buildCommand.isEmpty || !testCommand.isEmpty {
            var commandLines = ["Project commands (run these from the project folder when you need to verify your work):"]
            if !buildCommand.isEmpty { commandLines.append("- Build: \(buildCommand)") }
            if !testCommand.isEmpty { commandLines.append("- Test: \(testCommand)") }
            lines.append(commandLines.joined(separator: "\n"))
        }

        // Pinned files: the documents the user wants in front of the
        // agent on every run in this project.
        if !project.pinnedFilePaths.isEmpty {
            var pinnedLines = ["Pinned files — the user pinned these into every run in this project. Treat them as primary context:"]
            for relativePath in project.pinnedFilePaths {
                if let contents = AgentProjectSnapshot.pinnedFileContents(root: project.rootURL, relativePath: relativePath) {
                    pinnedLines.append("--- \(relativePath) ---\n\(contents)")
                } else {
                    pinnedLines.append("--- \(relativePath) --- (pinned, but the file could not be read — mention that if it matters)")
                }
            }
            lines.append(pinnedLines.joined(separator: "\n"))
        }

        // The Project Tool Mandate, in the context block as well as the
        // harness prompt, so every Agent path (MLX loop, Apple-model
        // runner) carries it.
        if project.requireToolUse {
            lines.append("TOOL MANDATE for this project: you must ALWAYS use/call tools when working in this project — no exceptions. Your first action must be a tool call that explores the project, and every claim about the project must be grounded in a tool result from this run. The runtime rejects a final answer given before any tool has run.")
        }

        let memory = project.memoryNewestFirst.prefix(memoryLimit)
        if memory.isEmpty {
            lines.append("Project memory: empty so far. When you learn a durable fact about this project (a decision, a convention, a gotcha, where things live), record it with the project memory tool so future sessions start from it.")
        } else {
            lines.append("Project memory — what you have remembered about THIS project from earlier sessions. Treat facts and instructions as established unless the current code or the user contradicts them:")
            for entry in memory {
                lines.append("- [\(entry.kind.label)] \(entry.text)")
            }
            lines.append("When this run teaches you something durable about the project, record it with the project memory tool (action: remember). Never record secrets, credentials, or transient output.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Persistence

    private func persist() {
        JSONFileStore.save(
            PersistedState(projects: projects, selectedProjectID: selectedProjectID),
            filename: Self.filename
        )
    }
}
