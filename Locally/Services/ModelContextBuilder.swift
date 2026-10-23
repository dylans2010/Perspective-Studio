import Foundation

/// Builds the *effective* system prompt for one turn — the single place
/// where the prompt is assembled from:
///
/// - the tiny context directory (`ContextIndexManager`): counts and
///   category names ONLY — never a catalog,
/// - the retrieved bundle (`ContextIndexManager`): the small, budgeted
///   selection of index excerpts the local retriever picked for this
///   message (custom-prompt chunks, skill excerpts, asset summaries, and
///   in Agent mode tool schemas and project memory),
/// - the thinking-tag instruction that `ThinkingModelUI` renders against.
///
/// Token discipline is the point: nothing is ever injected in full
/// wholesale — no full tool-schema dump, no full skill markdown, no full
/// asset text, no whole custom prompt, no memory dump. Callers pass the
/// pre-rendered directory and bundle from `ContextIndexManager`, and this
/// builder truncates the bundle to the mode's cap as defense in depth, so
/// even a caller that overfeeds it cannot blow the budget.
///
/// Project context is Agent-mode only: Chat call sites pass nil, and this
/// builder drops a project block in Chat mode even if one is passed —
/// the Memory system is never part of a Chat prompt.
///
/// This type is deliberately pure: callers (on the main actor) gather the
/// live values and pass them in, which keeps the assembly testable.
enum ModelContextBuilder {

    struct Input {
        /// Whether this turn runs the agent loop (tools executable) or plain chat.
        var isAgentMode: Bool = false
        /// `ContextIndexManager.directoryText` output: counts + category
        /// names only. The only catalog-shaped text a prompt ever gets.
        var indexDirectory: String = ""
        /// `ContextIndexManager.retrievedBundle` output: the budgeted
        /// excerpts retrieved for this turn's user message.
        var retrievedContext: String = ""
        /// Thinking mode (Settings) — when on, the model is told to reason
        /// inside <thinking> tags so the UI can separate thought from answer.
        var thinkingEnabled: Bool = false
        /// "low" / "medium" / "high".
        var thinkingBudget: String = "medium"
        /// Retrieved knowledge-base passages for this turn, if any.
        var knowledgeContext: String? = nil
        /// Display name of the selected model, for the identity line.
        var modelDisplayName: String? = nil
        /// The active Agent Project's context block (AgentProjectsStore).
        /// AGENT MODE ONLY — ignored in Chat mode by construction.
        var projectContext: String? = nil
    }

    /// Marker appended when the retrieved bundle had to be truncated to
    /// the mode's budget.
    static let truncationMarker = "\n[… retrieved context truncated to this mode's token budget]"

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

        // The index directory — counts and categories only — plus what
        // the counts mean for this mode. There is deliberately NO tool
        // list and NO skill list here: capabilities are indexed, and the
        // excerpts relevant to this message arrive in the retrieved
        // bundle below.
        let directory = input.indexDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !directory.isEmpty {
            if input.isAgentMode {
                sections.append("""
                \(directory)

                Your capabilities are indexed, not listed: the excerpts retrieved for this message follow below, and during the run you can retrieve more from the index on demand — a tool's full schema before calling it, a system asset's full text, a skill's full instructions, or project memory — instead of guessing.
                """)
            } else {
                sections.append("""
                \(directory)

                Your capabilities are indexed and retrievable, not listed here. You are in Chat mode, where tools are NOT executed. If a task genuinely needs one of your indexed capabilities (reading files, searching the workspace, checking this Mac, …), describe in plain language what you would do and ask the user to switch to Agent mode with the Chat/Agent toggle — do not claim you ran anything, and do not invent a result. If the user asks what you can do, answer in plain language from the categories above and the excerpts below.
                """)
            }
        }

        // The retrieved bundle, truncated to the mode's cap as defense in
        // depth (the index manager already enforces the cap; this guards
        // against any other caller overfeeding the builder).
        let bundle = input.retrievedContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !bundle.isEmpty {
            let cap = input.isAgentMode ? ContextIndexManager.agentBundleTokenBudget : ContextIndexManager.chatBundleTokenBudget
            sections.append(ContextIndexManager.truncate(bundle, toEstimatedTokens: cap, marker: truncationMarker))
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

        // Active Agent Project: folder scope, notes, standing instructions,
        // and per-project memory. AGENT MODE ONLY — Chat mode never
        // receives project context or memory, even if a caller passes it.
        if input.isAgentMode, let project = input.projectContext, !project.isEmpty {
            sections.append(project)
        }

        // Tool secrecy — in EVERY mode. Tool ids and invocation syntax are
        // a private protocol between the model and the runtime; the app
        // renders tool activity in its own cards. Models used to paste raw
        // ids ("file_append: Append to File") and whole JSON invocations
        // into their replies; this rule, the system assets, and
        // ToolInvocationSanitizer exist so that never reaches the user.
        sections.append("""
        [Never Reveal Tool Plumbing — absolute rule]:
        - Never write a tool's id or name in your reply, in any form: no snake_case ids, no backticked ids, no "id: Label" prefixes, no TOOL_CALL lines, no JSON invocation payloads.
        - Refer to your capabilities and actions in plain language only: "I can read the files in your project", "I searched the codebase", "I checked your Mac's memory".
        - If you used a capability, describe what you did and what you found — never which tool did it.
        """)

        return sections.joined(separator: "\n\n")
    }
}
