import Foundation

/// An explicit capability profile for the model/backend serving a turn.
///
/// Before this existed, prompt assembly and generation treated every
/// model as if it were equally capable: the same retrieved-bundle
/// budget, the same output cap reasoning, and an identity line that
/// named the *model* — which small models then answered with when asked
/// "what is your name?". Nothing in the codebase recorded whether a
/// backend offered native structured tool calling or only the
/// `TOOL_CALL` text protocol, what its context window was, or whether
/// the model was small enough that a long, multi-part system prompt
/// would crowd out the conversation.
///
/// This profile is derived only from facts the app actually knows:
/// - the Apple model: native tool calling on a bridged subset, ~4K
///   context (see `FoundationModelAgentRunner`), the reduced output cap
///   in `GenerationDefaults`;
/// - MLX models: the `TOOL_CALL` text protocol (no native structured
///   channel), streaming + per-token cancellation, context length
///   *unknown* unless a caller supplies one — unknown is represented as
///   `nil`, never guessed;
/// - parameter count parsed from the model id with the same patterns
///   `HFModel.parameterSize` uses. When the id carries no size, the
///   count is `nil` (unknown) and the model is NOT treated as
///   constrained on a guess.
///
/// The profile is a pure value: callers pass it into
/// `ModelContextBuilder`, which shortens the core prompt and tightens
/// the retrieved-bundle cap for constrained models instead of piling
/// more instructions onto the models least able to follow them.
public struct ModelCapabilityProfile: Sendable, Equatable {

    public enum Backend: String, Sendable, Equatable {
        case appleFoundationModels
        case mlx
        case unknown
    }

    /// How tool calls reach the runtime on this backend.
    public enum ToolCallingChannel: String, Sendable, Equatable {
        /// The provider's own structured tool interface (Apple model,
        /// bridged subset).
        case nativeStructured
        /// The validated `TOOL_CALL` text protocol (MLX models).
        case textProtocol
        case unknown
    }

    public var backend: Backend
    public var toolCalling: ToolCallingChannel
    public var supportsStreaming: Bool
    public var supportsCancellation: Bool
    /// Known context window in tokens; `nil` means unknown — callers
    /// must use conservative defaults rather than assuming a size.
    public var maxContextTokens: Int?
    /// Output cap actually enforced for this backend.
    public var maxOutputTokens: Int
    /// Parameter count in billions when the model id states one.
    public var parameterCountB: Double?
    /// Vision input is only claimed when the caller knows the model is
    /// a vision model; the profile never infers it from a name alone
    /// beyond the caller's explicit flag.
    public var supportsMultimodalInput: Bool

    public init(
        backend: Backend,
        toolCalling: ToolCallingChannel,
        supportsStreaming: Bool,
        supportsCancellation: Bool,
        maxContextTokens: Int?,
        maxOutputTokens: Int,
        parameterCountB: Double?,
        supportsMultimodalInput: Bool = false
    ) {
        self.backend = backend
        self.toolCalling = toolCalling
        self.supportsStreaming = supportsStreaming
        self.supportsCancellation = supportsCancellation
        self.maxContextTokens = maxContextTokens
        self.maxOutputTokens = maxOutputTokens
        self.parameterCountB = parameterCountB
        self.supportsMultimodalInput = supportsMultimodalInput
    }

    /// True for models whose instruction-following is limited enough
    /// that prompt economy matters more than prompt completeness: the
    /// Apple model (small, ~4K context) and MLX models at or below 3B
    /// parameters. Unknown size is NOT constrained — no guessing.
    public var isConstrained: Bool {
        if backend == .appleFoundationModels { return true }
        guard let parameterCountB else { return false }
        return parameterCountB <= 3.0
    }

    /// Fraction of the mode's retrieved-bundle budget a constrained
    /// model receives. Full budget for everyone else.
    public var bundleBudgetScale: Double { isConstrained ? 0.5 : 1.0 }

    /// Whether autonomous tool calling should be treated as reliable.
    /// Constrained models get the loop's existing guards plus an
    /// explicit capability note in the prompt; they are never silently
    /// trusted with the same latitude as a large model.
    public var toolCallingIsReliable: Bool { !isConstrained && toolCalling != .unknown }

    /// A plain-language Agent-mode compatibility warning for this
    /// profile, or nil when the model can be trusted with the agent
    /// loop as-is. The harness surfaces this in the run trace before a
    /// task run starts, so a user running a very small model (for
    /// example a 0.5B instruct model on the `TOOL_CALL` text protocol)
    /// is told up front that tool calling may be unreliable — instead
    /// of discovering it from a fabricated command or a run that never
    /// executes anything. Chat mode never shows this: chat stays fully
    /// usable on every model.
    public var agentModeAdvisory: String? {
        if toolCalling == .unknown {
            return "This model's tool-calling support is unknown, so Agent mode may not be able to carry out actions reliably. Chat mode is unaffected."
        }
        if isConstrained {
            return "This is a small model using the text tool-call protocol: Agent mode can attempt tool-based tasks, but its tool calling is unreliable — it may need corrections, and a task it cannot perform will be reported as not done rather than faked. A larger model will handle Agent mode more reliably. Chat mode is unaffected."
        }
        return nil
    }

    // MARK: - Derivation

    /// The built-in Apple model: native (bridged) tool calling, ~4K
    /// context, reduced output cap.
    public static var appleFoundationModels: ModelCapabilityProfile {
        ModelCapabilityProfile(
            backend: .appleFoundationModels,
            toolCalling: .nativeStructured,
            supportsStreaming: true,
            supportsCancellation: true,
            maxContextTokens: 4_096,
            maxOutputTokens: GenerationDefaults.maxAppleModelOutputTokens,
            parameterCountB: nil,
            supportsMultimodalInput: false
        )
    }

    /// A downloaded MLX model. Context length stays `nil` (unknown)
    /// unless the caller supplies the configured value.
    public static func mlx(modelID: String, isVisual: Bool = false, contextLength: Int? = nil) -> ModelCapabilityProfile {
        ModelCapabilityProfile(
            backend: .mlx,
            toolCalling: .textProtocol,
            supportsStreaming: true,
            supportsCancellation: true,
            maxContextTokens: contextLength,
            maxOutputTokens: GenerationDefaults.maxChatOutputTokens,
            parameterCountB: parameterCount(fromModelID: modelID),
            supportsMultimodalInput: isVisual
        )
    }

    /// No facts known: conservative on every axis.
    public static var unknown: ModelCapabilityProfile {
        ModelCapabilityProfile(
            backend: .unknown,
            toolCalling: .unknown,
            supportsStreaming: false,
            supportsCancellation: false,
            maxContextTokens: nil,
            maxOutputTokens: GenerationDefaults.maxChatOutputTokens,
            parameterCountB: nil,
            supportsMultimodalInput: false
        )
    }

    /// Resolves the profile for a selected model id the way the chat
    /// call sites do: the Apple model by its sentinel id, everything
    /// else as MLX.
    public static func profile(forModelID modelID: String?, isVisual: Bool = false) -> ModelCapabilityProfile {
        guard let modelID, !modelID.isEmpty else { return .unknown }
        if AppleFoundationModel.isAppleModel(modelID) { return .appleFoundationModels }
        return .mlx(modelID: modelID, isVisual: isVisual)
    }

    /// Parameter count in billions parsed from a model id ("7B",
    /// "0.5B", "270M"). Same intent as `HFModel.parameterSize`, with
    /// one correction: a negative lookahead keeps quantization
    /// suffixes from being misread as sizes — in
    /// "gemma-3-270m-it-4bit" the first naive `[Bb]` match is the "4b"
    /// of "4bit", which would report a 270M model as 4B.
    public static func parameterCount(fromModelID modelID: String) -> Double? {
        let name = modelID.replacingOccurrences(of: "mlx-community/", with: "")
        if let match = name.range(of: #"(\d+\.?\d*)[Bb](?![a-zA-Z])"#, options: .regularExpression) {
            return Double(name[match].dropLast())
        }
        if let match = name.range(of: #"(\d+\.?\d*)[Mm](?![a-zA-Z])"#, options: .regularExpression),
           let value = Double(name[match].dropLast()) {
            return value / 1_000.0
        }
        return nil
    }
}
