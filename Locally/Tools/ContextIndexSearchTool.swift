import Foundation

/// On-demand retrieval from the local context index (`ContextIndexManager`).
///
/// Prompts no longer carry full catalogs: the model starts a run with a
/// tiny directory (counts + categories) and a small bundle of excerpts the
/// local retriever picked for the user's message. When it needs more —
/// the exact schema of a tool it is about to call, the full text of a
/// skill or system asset, a custom-prompt chunk, a project-memory entry —
/// it asks the index with this tool and gets just those entries back,
/// full payloads, capped at the search budget.
///
/// Project memory is project-scoped: it is only searched when the run has
/// an active project (its id rides in the context). Without one, asking
/// for memory is a plain-language failure, and memory simply does not
/// appear in mixed-kind results.
public struct ContextIndexSearchTool: AssistTool {
    public let id = "context_index_search"
    public let name = "Context Index Search"
    public let description = "Search the local context index (tools, system assets, skills, custom prompts, project memory) and retrieve the full text of the best-matching entries — e.g. one tool's complete argument schema before calling it. Arguments: query (required), kind (optional: tool/systemAsset/skill/customPrompt/projectMemory/all), limit (optional, default 5, max 8)."
    public let capability = ToolCapability.general
    public let riskLevel = ToolRiskLevel.safeRead

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: "Searches the context index and returns matched entries' full payloads, capped in total size.",
            properties: [
                "query": JSONSchema(type: "string", description: "What to look for, in plain words (e.g. 'git commit history', 'screenshot', 'code review skill')."),
                "kind": JSONSchema(type: "string", description: "Optional filter: tool, systemAsset, skill, customPrompt, projectMemory, or all (default)."),
                "limit": JSONSchema(type: "number", description: "Optional maximum number of entries to return (default 5, max 8).")
            ],
            required: ["query"]
        )
    }

    public init() {}

    public func execute(input: [String: Any], context: AssistContext) async throws -> AssistToolResult {
        guard let query = (input["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            return .failure("Missing required parameter: 'query' — what to search the index for.", code: .missingArgument)
        }

        let kindArgument = (input["kind"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let kind: ContextIndexManager.Kind?
        switch kindArgument {
        case "", "all": kind = nil
        case "tool": kind = .tool
        case "systemasset": kind = .systemAsset
        case "skill": kind = .skill
        case "customprompt": kind = .customPrompt
        case "projectmemory": kind = .projectMemory
        default:
            return .failure("Unknown kind '\(kindArgument)'. Use tool, systemAsset, skill, customPrompt, projectMemory, or all.", code: .invalidInput)
        }

        // Memory is only reachable with an active project for the run.
        if kind == .projectMemory && context.agentProjectID == nil {
            return .failure("No project is selected for this run, so there is no project memory to search. Project memory is only available in Agent mode with a project selected.", code: .notFound)
        }

        let limit: Int
        if let number = input["limit"] as? NSNumber {
            limit = number.intValue
        } else if let text = input["limit"] as? String, let parsed = Int(text) {
            limit = parsed
        } else {
            limit = 5
        }

        let projectID = context.agentProjectID
        let output = await MainActor.run { () -> String in
            let project = projectID.flatMap { AgentProjectsStore.shared.project(id: $0) }
            var entries = ContextIndexManager.liveEntries(
                mode: .agent,
                globalCustomPrompt: UserDefaults.standard.string(forKey: "customSystemPrompt") ?? "",
                project: project
            )
            // Defensive: without a project, memory never appears — even
            // in a mixed-kind search (liveEntries only adds it with a
            // project, and this keeps that true if that ever changes).
            if project == nil {
                entries.removeAll { $0.kind == .projectMemory }
            }
            let results = ContextIndexManager.search(entries: entries, query: query, kind: kind, limit: limit)
            return ContextIndexManager.renderSearchResults(results)
        }
        return .success(output, data: ["query": query, "kind": kindArgument.isEmpty ? "all" : kindArgument])
    }
}
