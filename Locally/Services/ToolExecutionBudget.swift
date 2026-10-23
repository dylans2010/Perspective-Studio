import Foundation

/// A per-run cap on real tool executions, shared by every tool a run can
/// reach.
///
/// The MLX agent loop counts executions in its own loop state, but the
/// Apple-model path is driven by the Foundation Models framework: the
/// runner cannot count calls inside the framework's loop, so without a
/// shared budget that path had *no* execution cap at all — a model could
/// call tools until its context filled. Every bridged tool in a run now
/// claims a slot from the run's one budget before executing; a claim that
/// fails executes nothing and is reported to the model as a refusal, so
/// the run terminates honestly instead of spinning.
///
/// Thread-safe by lock: bridged tool calls arrive off the main actor.
public nonisolated final class ToolExecutionBudget: @unchecked Sendable {
    /// Maximum executions this budget allows (at least 1).
    public let limit: Int
    private let lock = NSLock()
    private var claimed = 0

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// Executions claimed so far.
    public var executedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return claimed
    }

    /// Claims one execution slot. Returns `false` — and claims nothing —
    /// when the run's tool budget is already exhausted.
    public func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard claimed < limit else { return false }
        claimed += 1
        return true
    }
}
