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
        /// The model asked to run a tool. The invocation itself is private
        /// plumbing and is consumed by the loop, never displayed.
        case callTool(toolID: String, arguments: [String: AnyCodableValue])
        /// The model produced its final answer for the user (already
        /// sanitized for display).
        case finalAnswer(String)

        public static func == (lhs: TurnDecision, rhs: TurnDecision) -> Bool {
            switch (lhs, rhs) {
            case (.callTool(let aID, let aArgs), .callTool(let bID, let bArgs)):
                return aID == bID && aArgs == bArgs
            case (.finalAnswer(let a), .finalAnswer(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    /// Classifies one raw model turn. A turn that contains a tool
    /// invocation is a tool turn even when the model surrounded it with
    /// prose — the prose of a tool turn is discarded by the loop, because
    /// half-formed explanations of plumbing are how raw invocations used to
    /// leak into the chat.
    public nonisolated static func decide(turnText: String, knownToolIDs: Set<String>) -> TurnDecision {
        if let parsed = AntigravityAgentHarness.parseToolCall(in: turnText) {
            let args = parsed.arguments.mapValues { AnyCodableValue(any: $0) }
            return .callTool(toolID: parsed.toolId, arguments: args)
        }
        return .finalAnswer(cleanFinalAnswer(turnText, knownToolIDs: knownToolIDs))
    }

    /// The user-turn text that feeds one tool result back into the loop.
    /// It names the action in human terms only — never the raw tool id —
    /// so even the model's context stops reinforcing id-naming.
    public nonisolated static func observationPrompt(toolID: String, output: String) -> String {
        """
        Tool result (from \(ToolNameFormatter.format(toolID))):
        \(output)

        Analyze this result and proceed to the next step, or provide the final answer if the task is complete. Remember: never mention tool names, ids, or invocation syntax in your answer — describe actions and findings in plain language.
        """
    }

    // MARK: - No-progress guard

    /// How many times the exact same tool call (same tool, same
    /// arguments) may execute in one run before the loop stops it: a
    /// third identical request cannot produce new information, and the
    /// old loop happily re-ran it until the turn cap.
    public nonisolated static let maxIdenticalToolExecutions = 2

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
        switch value {
        case let string as String:
            self = .string(string)
        case let bool as Bool:
            self = .bool(bool)
        case let number as NSNumber:
            self = .number(number.doubleValue)
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
