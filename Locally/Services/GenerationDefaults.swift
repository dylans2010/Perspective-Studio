import Foundation

/// Provider-aware generation defaults, in one testable place.
///
/// Before this existed, the MLX path built `GenerateParameters` from the
/// caller's temperature alone: no maximum output tokens (a chatty model
/// could generate until the context filled — the dozens-of-bullets
/// greeting failure ended only when the model felt like stopping), no
/// top-p, and a `nil` temperature silently meant "whatever the engine's
/// compiled-in default is", which differs per backend. Stop behaviour is
/// NOT invented here: MLX models stop on their tokenizer's EOS / chat
/// template end-of-turn token, and the Apple model stops on its own
/// completion — neither backend exposes a stop-string API, so none is
/// fabricated. What is bounded is length, sampling, and context.
///
/// The Apple-model paths use `maximumResponseTokens` with the same cap
/// (its ~4K context makes the cap more important, not less).
public enum GenerationDefaults {

    /// Fallback temperature when a conversation carries none: a natural
    /// conversational default — neither the near-greedy 0.0 some engines
    /// default to (repetitive loops) nor a creative-writing 1.0+.
    public nonisolated static let conversationalTemperature = 0.7

    /// Top-p applied on the MLX path alongside temperature.
    public nonisolated static let topP: Float = 0.95

    /// Hard output cap for a single Chat / Quick Chat generation.
    public nonisolated static let maxChatOutputTokens = 2_048

    /// Hard output cap for one Agent-mode model turn (the loop may take
    /// several turns; each one is individually bounded).
    public nonisolated static let maxAgentTurnOutputTokens = 2_048

    /// Output cap for the built-in Apple model, whose context window is
    /// ~4K tokens total — the answer must leave room for the prompt.
    public nonisolated static let maxAppleModelOutputTokens = 1_024

    /// Resolves an optional caller temperature to the effective value.
    public nonisolated static func temperature(_ caller: Double?) -> Double {
        guard let caller, caller.isFinite, caller >= 0 else { return conversationalTemperature }
        return min(caller, 2.0)
    }
}
