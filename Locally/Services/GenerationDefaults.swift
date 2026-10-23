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

    // MARK: - Duration limits
    //
    // Token caps bound *length*; they do not bound *time*. A model that
    // dribbles tokens, a backend that hangs before its first token, or an
    // agent loop that keeps making progress-shaped turns can each run
    // until the user force-quits — the "generation continues for an
    // excessive amount of time and the app becomes unresponsive" failure.
    // These wall-clock limits are enforced by the generation loops and
    // stream wrappers themselves (`StreamTimeout`, the harness's run
    // deadline, the engine actor's per-token checks), never merely
    // described to the model. A limit hit is a terminal state with an
    // explanation; work completed before it is preserved.

    /// Hard wall-clock cap for one Chat / Quick Chat generation.
    public nonisolated static let maxChatGenerationDuration: Duration = .seconds(300)

    /// Hard wall-clock cap for one model turn inside an agent run. A
    /// single turn that cannot finish in this time is stuck, not slow.
    public nonisolated static let maxAgentTurnDuration: Duration = .seconds(180)

    /// Hard wall-clock cap for a whole agent run, across all its turns
    /// and tool executions. Generous enough for real multi-step tasks;
    /// finite, so no run is unbounded.
    public nonisolated static let maxAgentRunDuration: Duration = .seconds(600)

    /// Minimum interval between streamed-text writes into the visible
    /// message. Token-by-token writes re-sanitize and re-render the whole
    /// accumulated response per token (quadratic in response length);
    /// flushing on this cadence keeps the UI responsive without changing
    /// what is finally rendered.
    public nonisolated static let streamFlushInterval: TimeInterval = 0.08

    /// Resolves an optional caller temperature to the effective value.
    public nonisolated static func temperature(_ caller: Double?) -> Double {
        guard let caller, caller.isFinite, caller >= 0 else { return conversationalTemperature }
        return min(caller, 2.0)
    }
}
