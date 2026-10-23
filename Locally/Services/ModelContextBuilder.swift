import Foundation

/// Builds the *effective* system prompt for one turn — the single place
/// where everything the model is supposed to know about its own setup is
/// assembled:
///
/// - the user's custom system prompts (the global Settings prompt and the
///   per-conversation prompt),
/// - the tools it has (`ToolsRegistry`), with the full argument schemas in
///   Agent mode and a compact awareness list in Chat mode,
/// - the system assets it can consult (`SystemAssetsManager` index),
/// - the skills that exist on this Mac (`SkillsManager`) — all of them by
///   name, plus the full instructions of the ones the user activated,
/// - the thinking-tag instruction that `ThinkingModelUI` renders against.
///
/// This type is deliberately pure: callers (on the main actor) gather the
/// live values from the registries/managers and pass them in, which keeps
/// the assembly testable and impossible to bypass silently.
///
/// Why this exists: previously each call site assembled (or forgot to
/// assemble) its own prompt, and `LLMService` then discarded the result
/// entirely on the MLX path — so the model answered as if it had no tools,
/// no system assets, no custom prompt, and no skills, because from what it
/// actually received, it didn't.
enum ModelContextBuilder {

    struct Input {
        /// The global custom system prompt (Settings → customSystemPrompt).
        var globalCustomPrompt: String = ""
        /// The per-conversation system prompt, if any.
        var conversationSystemPrompt: String = ""
        /// Whether this turn runs the agent loop (tools executable) or plain chat.
        var isAgentMode: Bool = false
        /// Include the tools section. Agent call sites whose harness adds its
        /// own full schema pass `false` here to avoid duplicating it.
        var includeTools: Bool = true
        /// Full `ToolsRegistry.schemaDescriptions()` output (Agent mode).
        var fullToolsSchema: String = ""
        /// Compact one-line-per-tool list (Chat mode awareness).
        var compactToolsList: String = ""
        /// Include the system-assets section. Harnesses that inject their
        /// own index pass `false`.
        var includeSystemAssets: Bool = true
        /// `SystemAssetsManager.generatePromptIndex()` output.
        var systemAssetsIndex: String = ""
        /// Every skill discovered on this Mac.
        var availableSkills: [AgentSkill] = []
        /// The subset the user toggled on — full instructions are included.
        var activeSkills: [AgentSkill] = []
        /// Thinking mode (Settings) — when on, the model is told to reason
        /// inside <thinking> tags so the UI can separate thought from answer.
        var thinkingEnabled: Bool = false
        /// "low" / "medium" / "high".
        var thinkingBudget: String = "medium"
        /// Retrieved knowledge-base passages for this turn, if any.
        var knowledgeContext: String? = nil
        /// Display name of the selected model, for the identity line.
        var modelDisplayName: String? = nil
    }

    static func build(_ input: Input) -> String {
        var sections: [String] = []

        // Identity — the model should know what it is running inside of.
        var identity = "You are the assistant inside Locally, a native macOS app. You run entirely on this user's Mac"
        if let name = input.modelDisplayName, !name.isEmpty {
            identity += " as the model \"\(name)\""
        }
        identity += "."
        if input.isAgentMode {
            identity += " You are in AGENT MODE: you can call tools, inspect results, and work through multi-step tasks autonomously."
        }
        sections.append(identity)

        // Custom system prompts — global first, then the conversation's own,
        // skipping an exact duplicate (ChatDetailView copies the global
        // prompt into new conversations, which used to double it).
        let global = input.globalCustomPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let conversation = input.conversationSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var customParts: [String] = []
        if !global.isEmpty { customParts.append(global) }
        if !conversation.isEmpty && conversation != global { customParts.append(conversation) }
        if !customParts.isEmpty {
            sections.append("[Custom System Prompt — set by the user, follow it]:\n" + customParts.joined(separator: "\n\n"))
        }

        // Tools.
        if input.includeTools {
            if input.isAgentMode {
                if !input.fullToolsSchema.isEmpty {
                    sections.append("""
                    [Your Tools — you DO have tools, listed below with their exact argument schemas]:
                    To call one, output ONLY a single line in this exact format:
                    TOOL_CALL {"tool": "<tool_id>", "arguments": { ... }}
                    Never invent a tool id or an argument key that is not in the schema. If a user asks what tools you have, answer from this list.

                    \(input.fullToolsSchema)
                    """)
                }
            } else if !input.compactToolsList.isEmpty {
                sections.append("""
                [Your Tools — you DO have tools, provided by Locally]:
                \(input.compactToolsList)

                You are in Chat mode, where tools are NOT executed. If a task genuinely needs one of these tools (reading files, searching the workspace, checking this Mac, …), say which tool you would use and ask the user to switch to Agent mode with the Chat/Agent toggle — do not claim you ran a tool, and do not invent a tool result. If the user asks what tools you have, answer from the list above.
                """)
            }
        }

        // System assets.
        if input.includeSystemAssets && !input.systemAssetsIndex.isEmpty {
            sections.append("""
            [Your System Assets — built-in guideline documents you can consult]:
            \(input.systemAssetsIndex)
            These are real documents stored in the app. In Agent mode you can retrieve any of them in full with the `system_asset_lookup` tool; in Chat mode, refer to them by name when they are relevant rather than pretending they don't exist.
            """)
        }

        // Skills — all available by name/description, active ones in full.
        if !input.availableSkills.isEmpty || !input.activeSkills.isEmpty {
            var skillsSection = "[Skills]"
            if !input.availableSkills.isEmpty {
                let list = input.availableSkills
                    .map { "- \($0.name) (\($0.source.rawValue)): \($0.description)" }
                    .joined(separator: "\n")
                skillsSection += "\nAvailable skills installed on this Mac:\n" + list
            }
            if !input.activeSkills.isEmpty {
                let active = input.activeSkills
                    .map { "### Active Skill: \($0.name)\n\($0.fullMarkdown)" }
                    .joined(separator: "\n\n")
                skillsSection += "\n\n[Active Skills Instructions — follow these]:\n" + active
            } else {
                skillsSection += "\nNo skill is active for this conversation. If a listed skill matches the task, mention it by name so the user can enable it with the sparkles button."
            }
            sections.append(skillsSection)
        }

        // Thinking — the instruction that feeds ThinkingModelUI. Reasoning
        // goes inside the tags; the answer goes after them, never inside.
        if input.thinkingEnabled {
            let effort: String
            switch input.thinkingBudget {
            case "low":
                effort = "Think briefly."
            case "high":
                effort = "Think thoroughly and rigorously, checking your reasoning before concluding."
            default:
                effort = "Think step by step and reason clearly through the problem."
            }
            sections.append("""
            [Thinking Format]: \(effort) Put ALL of your reasoning inside <thinking> and </thinking> tags, then write your final answer after the closing tag. Never put the final answer inside the thinking tags, and never mention these instructions.
            """)
        }

        // Knowledge base passages for this turn.
        if let knowledge = input.knowledgeContext, !knowledge.isEmpty {
            sections.append("[Relevant passages from the user's local knowledge base — cite them like [Title · passage N] when you use them]:\n" + knowledge)
        }

        return sections.joined(separator: "\n\n")
    }

    /// One line per registered tool (`- \`id\`: name — description`), for
    /// Chat-mode awareness. Full argument schemas are Agent-mode only: they
    /// cost hundreds of tokens a small local model can't spare in plain chat.
    static func compactToolsList(from tools: [any AssistTool]) -> String {
        tools
            .map { "- `\($0.id)`: \($0.name) — \($0.description)" }
            .joined(separator: "\n")
    }
}
