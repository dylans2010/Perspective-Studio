import Foundation

/// The identity and scope of one generation run.
///
/// Before this existed, a "run" was an anonymous `Task` plus shared mutable
/// flags (a single `isCancelled` Bool on the engine actor, a single
/// `isGenerating` on the view model). Two consequences followed directly
/// from that shape:
///
/// - Cancelling was not scoped: a new generation reset the shared flag, so
///   a stop aimed at the previous run silently stopped working — and a
///   stop that did land could just as easily kill the *newer* run.
/// - Nothing could tell a late event from a current one: a token, a tool
///   result, or a final answer produced by an earlier run was applied to
///   whatever conversation happened to be on screen when it arrived.
///
/// Every run now carries a `GenerationRun` value: a unique id, the
/// conversation it belongs to, and its start time. Stream consumers apply
/// an event only while `shouldApply(eventRunID:activeRunID:)` holds for
/// their run, and duration limits are measured from `startedAt` — so a
/// cancelled or superseded run cannot write into its successor, and a
/// newer run is never cancelled by an older run's stop.
public struct GenerationRun: Sendable, Equatable, Identifiable {
    public let id: UUID
    /// The conversation this run writes into. Tool calls, streaming
    /// events, and the final answer are valid only for this conversation.
    public let conversationID: UUID?
    public let startedAt: Date

    public init(id: UUID = UUID(), conversationID: UUID? = nil, startedAt: Date = .now) {
        self.id = id
        self.conversationID = conversationID
        self.startedAt = startedAt
    }

    /// True while this run is the active one. A superseded or finished
    /// run fails this check, which is what drops its late events.
    public func isCurrent(activeRunID: UUID?) -> Bool {
        activeRunID == id
    }

    /// The single gate every run-scoped event passes through before it
    /// may touch UI or persisted state: the event's run must still be the
    /// active run. Events from any other run — older, cancelled, or from
    /// another conversation — are dropped, never applied.
    public nonisolated static func shouldApply(eventRunID: UUID, activeRunID: UUID?) -> Bool {
        activeRunID == eventRunID
    }

    /// Seconds this run has been alive at `now`.
    public func elapsed(now: Date = .now) -> TimeInterval {
        max(0, now.timeIntervalSince(startedAt))
    }

    /// True when the run has exceeded `limit` at `now`. Duration limits
    /// are enforced by the generation loops themselves (they stop and
    /// report a terminal timeout state); this value is how they decide.
    public func hasExceeded(limit: Duration, now: Date = .now) -> Bool {
        elapsed(now: now) > Self.seconds(from: limit)
    }

    /// Time left before `limit` expires at `now` (`.zero` when expired).
    public func remaining(limit: Duration, now: Date = .now) -> Duration {
        let left = Self.seconds(from: limit) - elapsed(now: now)
        return .seconds(max(0, left))
    }

    public nonisolated static func seconds(from duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
