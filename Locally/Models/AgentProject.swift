import Foundation

/// One durable fact the agent must remember about a specific project.
///
/// Memory entries are written three ways, all into the same store:
/// - by the user, in Settings → Projects (or the project memory editor),
/// - by the agent itself during a run, through the project memory tool,
/// - automatically after each agent run in the project, as a session note
///   summarizing the task and its outcome.
public struct AgentProjectMemoryEntry: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var text: String
    public var createdAt: Date
    /// Where the entry came from, so the UI (and the model) can weigh it.
    public var kind: Kind

    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// A durable fact, decision, convention, or gotcha about the project.
        case fact
        /// A standing instruction for how the agent should work in it.
        case instruction
        /// An automatic note of one agent session (task + outcome).
        case session

        public var label: String {
            switch self {
            case .fact: "Fact"
            case .instruction: "Instruction"
            case .session: "Session"
            }
        }
    }

    public init(id: UUID = UUID(), text: String, createdAt: Date = .now, kind: Kind = .fact) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.kind = kind
    }
}

/// An Agent Project: a folder (usually a codebase) the agent works inside,
/// with its own persistent memory.
///
/// Selecting a project in Agent mode scopes the whole run to it: the
/// project's folder becomes the workspace root every file/search tool
/// resolves against, and the project's notes + memory are injected into the
/// agent's context so it works the way this project needs — and remembers
/// what it learned here, per project, across sessions.
public struct AgentProject: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    /// Absolute path of the project folder on this Mac.
    public var rootPath: String
    /// User-written description of what this project is.
    public var notes: String
    /// Standing instructions for the agent whenever this project is active.
    public var instructions: String
    public var memory: [AgentProjectMemoryEntry]
    public var createdAt: Date
    public var updatedAt: Date
    /// Files (paths relative to the project root) whose contents are
    /// injected into every Agent run in this project — the project's
    /// key documents the agent should always have in front of it.
    public var pinnedFilePaths: [String] = []
    /// The project's build command, when the user has set one. Injected
    /// into the run context so the agent verifies the way the project
    /// itself does instead of guessing a command.
    public var buildCommand: String = ""
    /// The project's test command, companion to `buildCommand`.
    public var testCommand: String = ""
    /// The Project Tool Mandate switch: while true (the default), an
    /// Agent run in this project may not finish without having used its
    /// tools — the loop rejects tool-less final answers
    /// (`AgentToolPolicy`). Users can turn it off per project for
    /// purely conversational projects.
    public var requireToolUse: Bool = true

    public init(
        id: UUID = UUID(),
        name: String,
        rootPath: String,
        notes: String = "",
        instructions: String = "",
        memory: [AgentProjectMemoryEntry] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now,
        pinnedFilePaths: [String] = [],
        buildCommand: String = "",
        testCommand: String = "",
        requireToolUse: Bool = true
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.notes = notes
        self.instructions = instructions
        self.memory = memory
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.pinnedFilePaths = pinnedFilePaths
        self.buildCommand = buildCommand
        self.testCommand = testCommand
        self.requireToolUse = requireToolUse
    }

    // Projects persisted before the pinned-files / commands / mandate
    // fields existed must still decode — a synthesized decoder would
    // throw on the missing keys and silently drop the user's projects.
    private enum CodingKeys: String, CodingKey {
        case id, name, rootPath, notes, instructions, memory, createdAt, updatedAt
        case pinnedFilePaths, buildCommand, testCommand, requireToolUse
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        rootPath = try container.decode(String.self, forKey: .rootPath)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        instructions = try container.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        memory = try container.decodeIfPresent([AgentProjectMemoryEntry].self, forKey: .memory) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
        pinnedFilePaths = try container.decodeIfPresent([String].self, forKey: .pinnedFilePaths) ?? []
        buildCommand = try container.decodeIfPresent(String.self, forKey: .buildCommand) ?? ""
        testCommand = try container.decodeIfPresent(String.self, forKey: .testCommand) ?? ""
        requireToolUse = try container.decodeIfPresent(Bool.self, forKey: .requireToolUse) ?? true
    }

    public nonisolated var rootURL: URL { URL(fileURLWithPath: rootPath) }

    /// Whether the folder still exists — a project whose folder was moved
    /// or deleted stays listed (its memory is valuable) but cannot scope a
    /// run until the user re-points it in Settings.
    public nonisolated var folderExists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Memory newest-first, the order the agent reads it in.
    public nonisolated var memoryNewestFirst: [AgentProjectMemoryEntry] {
        memory.sorted { $0.createdAt > $1.createdAt }
    }
}
