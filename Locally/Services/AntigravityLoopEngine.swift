import Foundation

/// The bundled Antigravity loop engine — the agent-loop layer of the
/// Antigravity SDK as shipped inside Locally (see
/// `AntigravitySDKBundle` for the bundled upstream SDK it accompanies).
///
/// The loop engine is deliberately *only* a loop. It contains:
/// - no model: inference is supplied by the caller (`InferenceBackend` —
///   the user's local MLX models or the built-in Apple model),
/// - no tools: execution is supplied by the caller (`ToolsRegistry` —
///   Locally's own registered tools),
/// - no networking, accounts, or cloud state of any kind.
///
/// It owns the turn-by-turn decisions every agent run depends on:
/// classifying a model turn as a tool call or a final answer, building the
/// observation prompt that feeds a tool result back into the loop, and
/// cleaning a final answer so private protocol syntax (tool invocations,
/// raw tool identifiers) never reaches the user.
public enum AntigravityLoopEngine {

    /// The bundled loop engine's own version, independent of the upstream
    /// SDK version it is shipped alongside.
    public static let version = "1.0.0"

    /// What one model turn means for the loop.
    public enum TurnDecision: Sendable, Equatable {
        /// The model asked to run a tool, and the request was validated
        /// against the registry. The invocation itself is private plumbing and
        /// is consumed by the loop, never displayed.
        case callTool(toolID: String, arguments: [String: AnyCodableValue])
        /// The model asked to run multiple tools in a single turn. They
        /// are executed sequentially by the harness and their observations
        /// are fed back together into the loop.
        case callTools([(toolID: String, arguments: [String: AnyCodableValue])])
        /// The model asked for an action that cannot run: an unregistered
        /// tool, unreadable payload, or arguments its schema rejects. Nothing
        /// is executed; the loop feeds the reason back so the model can
        /// correct itself or report the limitation.
        case invalidToolCall(toolID: String, rejection: ToolCallRejection)
        /// The model produced its final answer for the user (already
        /// sanitized for display).
        case finalAnswer(String)

        /// Whether this turn was an attempt to act (valid or not). Direct
        /// turns use this to escalate into the loop.
        public var isToolAttempt: Bool {
            switch self {
            case .callTool, .callTools, .invalidToolCall: true
            case .finalAnswer: false
            }
        }

        public static func == (lhs: TurnDecision, rhs: TurnDecision) -> Bool {
            switch (lhs, rhs) {
            case (.callTool(let aID, let aArgs), .callTool(let bID, let bArgs)):
                return aID == bID && aArgs == bArgs
            case (.callTools(let aList), .callTools(let bList)):
                guard aList.count == bList.count else { return false }
                for (a, b) in zip(aList, bList) {
                    if a.toolID != b.toolID || a.arguments != b.arguments { return false }
                }
                return true
            case (.invalidToolCall(let aID, let aRejection), .invalidToolCall(let bID, let bRejection)):
                return aID == bID && aRejection == bRejection
            case (.finalAnswer(let a), .finalAnswer(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    /// Classifies one raw model turn against the registry.
    ///
    /// A turn is a tool turn **only** when it carries the runtime's tool-call
    /// channel (`TOOL_CALL …` or a `<tool_call>` wrapper) *and* the requested
    /// id resolves to a registered tool *and* its arguments match that tool's
    /// schema. Everything else is a final answer. Prose — including a command
    /// printed in a fenced code block — is never parsed as an invocation, and
    /// a mentioned-but-unregistered id is refused rather than dispatched.
    ///
    /// A tool turn's prose is discarded by the loop: half-formed explanations
    /// of plumbing are how raw invocations used to leak into the chat.
    public nonisolated static func decide(turnText: String, catalog: ToolCatalog) -> TurnDecision {
        let calls = AntigravityAgentHarness.parseToolCalls(in: turnText)
        if !calls.isEmpty {
            var validCalls: [(toolID: String, arguments: [String: AnyCodableValue])] = []
            for parsed in calls {
                let args = parsed.arguments.mapValues { AnyCodableValue(any: $0) }
                switch ToolCallValidator.validate(toolID: parsed.toolId, arguments: args, catalog: catalog) {
                case .accepted(let call):
                    validCalls.append((toolID: call.toolID, arguments: call.arguments))
                case .rejected(let rejection):
                    return .invalidToolCall(toolID: parsed.toolId, rejection: rejection)
                }
            }
            if validCalls.count == 1 {
                return .callTool(toolID: validCalls[0].toolID, arguments: validCalls[0].arguments)
            } else if validCalls.count > 1 {
                return .callTools(validCalls)
            }
        }
        // The model used the tool-call channel but the payload could not be
        // read. That is an invalid call, not an answer: rendering it would
        // print protocol text, and executing anything would be a guess.
        if AntigravityAgentHarness.containsToolCallChannel(turnText) {
            return .invalidToolCall(toolID: "", rejection: .malformedCall)
        }
        return .finalAnswer(cleanFinalAnswer(turnText, knownToolIDs: catalog.ids))
    }

    /// Ids-only classification (no schemas available). Argument validation is
    /// skipped; identity is still resolved against the registry, and an
    /// unregistered id is refused instead of dispatched.
    public nonisolated static func decide(turnText: String, knownToolIDs: Set<String>) -> TurnDecision {
        decide(turnText: turnText, catalog: ToolCatalog(permissiveIDs: knownToolIDs))
    }

    /// The user-turn text that feeds one tool result back into the loop.
    /// It names the action in human terms only — never the raw tool id —
    /// so even the model's context stops reinforcing id-naming.
    public nonisolated static func observationPrompt(toolID: String, output: String, success: Bool = true) -> String {
        let statusLine = success
            ? ""
            : "This action FAILED — it is an error result, not an observation. Do not describe it as done; report the failure in plain language and choose a different next step.\n"
        return """
        Tool result (from \(ToolNameFormatter.format(toolID))):
        \(statusLine)\(output)

        Analyze this result and proceed to the next step, or provide the final answer if the task is complete. Remember: never mention tool names, ids, or invocation syntax in your answer — describe actions and findings in plain language.
        """
    }

    /// The user-turn text that feeds multiple tool results from a single turn back into the loop.
    public nonisolated static func multiObservationPrompt(results: [(toolID: String, output: String, success: Bool)]) -> String {
        var blocks: [String] = []
        for r in results {
            let statusLine = r.success
                ? ""
                : "This action FAILED — it is an error result, not an observation. Do not describe it as done; report the failure in plain language and choose a different next step.\n"
            blocks.append("""
            Tool result (from \(ToolNameFormatter.format(r.toolID))):
            \(statusLine)\(r.output)
            """)
        }
        let joined = blocks.joined(separator: "\n\n")
        return """
        \(joined)

        Analyze these results and proceed to the next step, or provide the final answer if the task is complete. Remember: never mention tool names, ids, or invocation syntax in your answer — describe actions and findings in plain language.
        """
    }

    /// The user turn fed back when the model requested an action that cannot
    /// run. It states the rule and the specific defect, and pushes the model
    /// to either make one corrected call or say the capability is missing.
    public nonisolated static func correctionPrompt(rejection: ToolCallRejection) -> String {
        """
        Nothing was executed for your last request. \(rejection.modelFacingExplanation)

        How to act in this runtime:
        - A tool runs only when you emit exactly one line: TOOL_CALL {"tool": "<registered id>", "arguments": { ... }}
        - Only call ids that appear in your tool set, or retrieve a tool's exact schema from the context index first. Writing a tool name, a shell command, or a JSON example in prose does nothing — it is not an invocation.
        - If this runtime has no tool for what the task needs, say so plainly instead of describing the action as if it happened.
        """
    }

    /// The user turn fed back when the model *describes* work or asserts capability
    /// instead of doing it (the "I can read the files..." or "I will run it now" turn
    /// with no call attached).
    public nonisolated static let narrationCorrectionPrompt = """
    You described an action or stated a capability but did not request one, so nothing ran. You must NOT merely state that you can read, search, or inspect files — you MUST emit a TOOL_CALL now.

    Either request the action now as exactly one line — TOOL_CALL {"tool": "<registered id>", "arguments": { ... }} — or, if this runtime has no tool that can do it, tell the user truthfully that it cannot be done here and stop. Never state or imply that an action happened when no tool ran.
    """

    // MARK: - No-progress guard

    /// How many times the exact same tool call (same tool, same
    /// arguments) may execute in one run before the loop stops it: a
    /// third identical request cannot produce new information, and the
    /// old loop happily re-ran it until the turn cap.
    public nonisolated static let maxIdenticalToolExecutions = 2

    /// How many rejected (unregistered / malformed / schema-invalid) calls
    /// one run may make. The first rejection is fed back as a correction; a
    /// model that keeps asking for something that cannot run is stopped rather
    /// than left to burn the turn budget.
    public nonisolated static let maxRejectedToolCalls = 2

    /// How many consecutive narration-without-action turns one run may make
    /// before it stops. The first is corrected; a second means the model is
    /// not going to act, so the run ends with an honest status instead of
    /// repeating the same paragraph.
    public nonisolated static let maxNarrationTurns = 2

    /// Upper bound on real tool executions in one run.
    public nonisolated static let maxToolExecutionsPerRun = 24

    /// First-person future-intent phrases that mark a turn as an announcement
    /// of pending work. Deliberately narrow: only explicit self-action
    /// announcements, never ordinary second-person instructions ("you can run
    /// …") or sign-offs ("let me know").
    private nonisolated static let pendingActionPhrases: [String] = [
        "i will now", "i'll now", "i will use", "i'll use", "i am going to", "i'm going to",
        "i will run", "i'll run", "i will attach", "i'll attach", "i will call", "i'll call",
        "i will execute", "i'll execute", "i will launch", "i'll launch",
        "let me run", "let me use", "let me attach", "let me execute", "let me launch",
        "next, i will", "next i will", "next, i'll", "next i'll", "now i will", "now i'll",
        "running the command", "attaching the debugger"
    ]

    /// First-person capability statements and action narration: asserting
    /// the ability or intent to inspect, read, check, search, or access
    /// code/files without actually emitting a tool call.
    private nonisolated static let capabilityStatements: [String] = [
        "i can read", "i can inspect", "i can check", "i can search", "i can access",
        "i am able to read", "i will look for", "i'll look for", "let me look for",
        "i will inspect", "i'll inspect", "let me inspect", "let me check", "i'll check",
        "i can check", "i will check", "i'll read", "i will read", "let me read",
        "i'll search", "i will search", "let me search", "i'll find", "i will find",
        "let me find"
    ]

    /// Words that make an announcement an announcement of *work* (running,
    /// attaching, invoking a tool) rather than ordinary first-person prose.
    private nonisolated static let pendingActionMarkers: [String] = [
        "tool", "command", "terminal", "shell", "debugger", "debug ", "attach",
        "run ", "runs", "execute", "launch", "bash", "script", "build", "xcodebuild"
    ]

    /// File and inspection keywords: when present alongside a pending action,
    /// the turn is an unexecuted file/code action even without shell/command markers.
    private nonisolated static let fileOrCodeKeywords: [String] = [
        "file", "files", "code", "directory", "folder", "workspace", "repo", "repository", "project"
    ]

    private nonisolated static let inspectionKeywords: [String] = [
        "read", "reading", "search", "searching", "inspect", "inspecting", "look for", "looking for", "find", "check"
    ]

    /// True when the text announces work the model is about to do rather than
    /// reporting work that was done. Used by the loop to refuse an
    /// announcement as a final answer: an announced action that was never
    /// requested through the tool channel is not a completed task.
    ///
    /// Catches explicit capability statements ("I can read the files..."),
    /// action narrations ("Let me search for..."), and future-work phrases.
    public nonisolated static func describesPendingAction(_ text: String) -> Bool {
        let lowered = text.lowercased()

        // 1. Direct match on capability statements and action narration:
        if capabilityStatements.contains(where: { lowered.contains($0) }) {
            return true
        }

        // 2. Pending action phrases with command markers, code blocks, or file/code inspection intent:
        guard pendingActionPhrases.contains(where: { lowered.contains($0) }) else { return false }
        if text.contains("```") { return true }
        if pendingActionMarkers.contains(where: { lowered.contains($0) }) { return true }

        // Do not require pendingActionMarkers if the phrase explicitly mentions reading, searching, inspecting, or looking for files/code!
        let mentionsFileOrCode = fileOrCodeKeywords.contains { lowered.contains($0) }
        let mentionsInspection = inspectionKeywords.contains { lowered.contains($0) }
        if mentionsFileOrCode && mentionsInspection {
            return true
        }

        return false
    }

    /// A narration signature for no-progress detection: the same announcement
    /// repeated cannot start producing results.
    public nonisolated static func narrationSignature(_ text: String) -> String {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return "narration|" + words.joined(separator: " ")
    }

    /// A signature for ANY assistant text turn, narration or not: the
    /// normalized words, order preserved, punctuation and case removed.
    /// Two turns with the same signature are the same text for
    /// progress purposes, however they are punctuated.
    public nonisolated static func textTurnSignature(_ text: String) -> String {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return "text|" + words.joined(separator: " ")
    }

    /// How many times one run may produce the *same* assistant text turn
    /// (same signature) while the loop continues past it — e.g. the same
    /// tool-state sentence ("that tool was not called") or the same
    /// rejected draft answer re-sent after a correction. One occurrence
    /// is the turn itself; a repeat means nothing about the model's
    /// situation changed when it said the same thing again, so the run
    /// stops instead of re-asking. Tool-call repetition is bounded
    /// separately (`maxIdenticalToolExecutions`); this bounds *text*
    /// repetition, which the tool guard cannot see.
    public nonisolated static let maxIdenticalTextTurns = 1

    /// True when this text turn repeats one the run already produced —
    /// i.e. the run is looping on prose, not progressing.
    public nonisolated static func isRepeatedTextTurn(signature: String, previousSignatures: [String]) -> Bool {
        previousSignatures.filter { $0 == signature }.count >= maxIdenticalTextTurns
    }

    /// Canonical signature of one tool call for repetition detection.
    /// `canonicalArguments` must be a deterministic rendering of the
    /// arguments (the harness passes sorted-keys JSON).
    public nonisolated static func toolCallSignature(toolID: String, canonicalArguments: String) -> String {
        "\(toolID)|\(canonicalArguments)"
    }

    /// True when executing this call again would be a no-progress repeat.
    public nonisolated static func isNoProgressRepeat(signature: String, previousSignatures: [String]) -> Bool {
        previousSignatures.filter { $0 == signature }.count >= maxIdenticalToolExecutions
    }

    /// Splits a model turn into its reasoning and its answer using the
    /// same parser the chat UI renders with (`ThinkingContentParser`).
    /// Agent turns need this as much as chat turns do: a reasoning model's
    /// `<thinking>` block must surface as a *thought* step (rendered by
    /// the thinking UI), never as part of the final answer text.
    public nonisolated static func splitThinking(from text: String) -> (thinking: String?, answer: String) {
        let parsed = ThinkingContentParser.parse(text)
        return (parsed.hasThinking ? parsed.thinkingText : nil, parsed.answer)
    }

    /// Cleans a model's final answer for display: strips an `Assistant:`
    /// prefix, removes any tool invocations the model echoed, and redacts
    /// raw tool identifiers.
    public nonisolated static func cleanFinalAnswer(_ text: String, knownToolIDs: Set<String>) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("Assistant:") {
            cleaned = String(cleaned.dropFirst("Assistant:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ToolInvocationSanitizer.displayText(for: cleaned, knownToolIDs: knownToolIDs)
    }
}

/// A minimal type-erased codable value so loop decisions can carry tool
/// arguments without leaking `[String: Any]` through the SDK surface.
public nonisolated enum AnyCodableValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([AnyCodableValue])
    case object([String: AnyCodableValue])

    public nonisolated init(any value: Any) {
        // NSNumber must be inspected before Bool: JSON numbers bridge to
        // Bool on Apple platforms, so `NSNumber(value: 1) as? Bool` succeeds
        // and an integer argument would silently become `true`.
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
            return
        }
        switch value {
        case let string as String:
            self = .string(string)
        case let bool as Bool:
            self = .bool(bool)
        case let array as [Any]:
            self = .array(array.map { AnyCodableValue(any: $0) })
        case let object as [String: Any]:
            self = .object(object.mapValues { AnyCodableValue(any: $0) })
        case is NSNull:
            self = .null
        default:
            self = .string(String(describing: value))
        }
    }

    /// Back to the untyped dictionary value `ToolsRegistry` executes with.
    public nonisolated var anyValue: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .null: return NSNull()
        case .array(let values): return values.map { $0.anyValue }
        case .object(let object): return object.mapValues { $0.anyValue }
        }
    }
}
