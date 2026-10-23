import Foundation

/// The terminal error a generation produces when its duration limit
/// expires. It is a distinct type (not a message string) so callers can
/// tell "the user stopped this" (`CancellationError` / `Task.isCancelled`)
/// from "the safeguard stopped this" and report each truthfully: work
/// completed before the limit is preserved, and the timeout is stated as
/// the reason the run ended.
public struct GenerationTimeoutError: Error, LocalizedError, Sendable {
    /// The limit that expired, in seconds (for the user-facing message).
    public let limitSeconds: Int

    public init(limit: Duration) {
        self.limitSeconds = Int(GenerationRun.seconds(from: limit).rounded(.up))
    }

    public var errorDescription: String? {
        "Generation stopped after \(limitSeconds)s — the time limit for one response was reached. What was produced before the limit is kept; ask again or split the request if you need more."
    }
}

/// Applies a hard wall-clock deadline to a generation stream.
///
/// Token caps alone do not bound a run: a model can dribble tokens
/// indefinitely under the cap, and a hung backend can produce *no* tokens
/// while the consumer waits forever — both presented as the app freezing
/// with the stop control as the only way out. Wrapping a stream here
/// guarantees the consumer's loop terminates: when the deadline passes,
/// the producer task is cancelled (which is what actually stops the
/// underlying generation where the backend cooperates) and the stream
/// finishes with `GenerationTimeoutError` instead of waiting.
///
/// Cancellation of the *consuming* task also tears the producer down via
/// `onTermination`, so a user stop and a timeout take the same path.
public enum StreamTimeout {

    /// Deadline-wraps a backend event stream (`InferenceBackend`).
    public nonisolated static func events(
        _ base: AsyncThrowingStream<GenerationEvent, Error>,
        after timeout: Duration
    ) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    for try await event in base {
                        if Task.isCancelled { break }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let watchdog = Task {
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                // Finishing an already-finished continuation is a no-op,
                // so a producer that completed just before the deadline
                // keeps its normal result; a live one is cancelled first.
                producer.cancel()
                continuation.finish(throwing: GenerationTimeoutError(limit: timeout))
            }
            continuation.onTermination = { _ in
                producer.cancel()
                watchdog.cancel()
            }
        }
    }

    /// Deadline-wraps a token stream (the MLX chat path speaks
    /// `AsyncStream<String>`; the wrapped form throws so the timeout is
    /// visible to the caller's error handling instead of looking like a
    /// clean end-of-stream).
    public nonisolated static func tokens(
        _ base: AsyncStream<String>,
        after timeout: Duration
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                for await token in base {
                    if Task.isCancelled { break }
                    continuation.yield(token)
                }
                continuation.finish()
            }
            let watchdog = Task {
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                producer.cancel()
                continuation.finish(throwing: GenerationTimeoutError(limit: timeout))
            }
            continuation.onTermination = { _ in
                producer.cancel()
                watchdog.cancel()
            }
        }
    }
}
