import Foundation

/// Per-project memory for the agent.
///
/// Every Agent Project has a persistent memory (facts, standing
/// instructions, and session notes) that is injected into the agent's
/// context at the start of each run in that project. This tool is how the
/// agent maintains that memory itself: `remember` records a durable fact
/// it learned, `recall` reads the memory back mid-run, and `forget`
/// removes an entry that turned out to be wrong.
///
/// Memory is strictly per project — the run's context carries the active
/// project's id, and this tool refuses to touch any other project's memory.
public struct ProjectMemoryTool: AssistTool {
    public let id = "project_memory"
    public let name = "Project Memory"
    public let description = "Read or update the active project's persistent memory. Actions: remember (record a durable fact, decision, convention, or gotcha about this project — argument: text), recall (read the project's memory), forget (remove the entry whose text matches — argument: text). Only works when a project is selected for the run."
    public let capability = ToolCapability.memory
    public let riskLevel = ToolRiskLevel.safeMutation

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: "Maintains the active Agent Project's persistent memory.",
            properties: [
                "action": JSONSchema(type: "string", description: "One of: remember, recall, forget."),
                "text": JSONSchema(type: "string", description: "For remember: the fact to record. For forget: the exact text (or a distinctive substring) of the entry to remove.")
            ],
            required: ["action"]
        )
    }

    public init() {}

    public func execute(input: [String: Any], context: AssistContext) async throws -> AssistToolResult {
        guard let projectID = context.agentProjectID else {
            return .failure("No project is selected for this run, so there is no project memory to use. Continue without it, and if the user wants the agent to remember this work, suggest selecting or adding a project in Agent mode.", code: .notFound)
        }

        let action = ((input["action"] as? String) ?? "").lowercased()

        switch action {
        case "remember":
            guard let text = (input["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                return .failure("Missing required parameter: 'text' — the fact to remember.", code: .missingArgument)
            }
            let recorded = await MainActor.run { () -> Bool in
                guard AgentProjectsStore.shared.project(id: projectID) != nil else { return false }
                AgentProjectsStore.shared.addMemoryEntry(projectID: projectID, text: text, kind: .fact)
                return true
            }
            return recorded
                ? .success("Remembered for this project: \(text)")
                : .failure("That project no longer exists, so nothing was recorded.", code: .notFound)

        case "recall":
            let entries = await MainActor.run {
                AgentProjectsStore.shared.project(id: projectID)?.memoryNewestFirst ?? []
            }
            guard !entries.isEmpty else {
                return .success("This project's memory is empty so far.")
            }
            let listing = entries
                .map { "- [\($0.kind.label)] \($0.text)" }
                .joined(separator: "\n")
            return .success("Project memory:\n\(listing)")

        case "forget":
            guard let text = (input["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                return .failure("Missing required parameter: 'text' — what to forget.", code: .missingArgument)
            }
            let removed = await MainActor.run { () -> Int in
                let store = AgentProjectsStore.shared
                guard let project = store.project(id: projectID) else { return 0 }
                let matches = project.memory.filter {
                    $0.text == text || $0.text.localizedStandardContains(text)
                }
                for entry in matches {
                    store.removeMemoryEntry(projectID: projectID, entryID: entry.id)
                }
                return matches.count
            }
            return removed > 0
                ? .success("Forgot \(removed) memory entr\(removed == 1 ? "y" : "ies") matching that text.")
                : .success("No memory entry matched that text, so nothing was removed.")

        default:
            return .failure("Unknown action '\(action)'. Use remember, recall, or forget.", code: .invalidInput)
        }
    }
}
