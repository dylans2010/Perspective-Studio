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

    public init(
        id: UUID = UUID(),
        name: String,
        rootPath: String,
        notes: String = "",
        instructions: String = "",
        memory: [AgentProjectMemoryEntry] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.notes = notes
        self.instructions = instructions
        self.memory = memory
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var rootURL: URL { URL(fileURLWithPath: rootPath) }

    /// Whether the folder still exists — a project whose folder was moved
    /// or deleted stays listed (its memory is valuable) but cannot scope a
    /// run until the user re-points it in Settings.
    public var folderExists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Memory newest-first, the order the agent reads it in.
    public var memoryNewestFirst: [AgentProjectMemoryEntry] {
        memory.sorted { $0.createdAt > $1.createdAt }
    }
}
