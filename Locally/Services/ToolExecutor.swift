import Foundation

/// The measured result of one tool execution.
public struct ToolExecutionOutcome: Sendable {
    public let result: AssistToolResult
    public let duration: TimeInterval
    public let timedOut: Bool

    public nonisolated init(result: AssistToolResult, duration: TimeInterval, timedOut: Bool) {
        self.result = result
        self.duration = duration
        self.timedOut = timedOut
    }
}

/// Runs a validated tool call against its real implementation.
///
/// This is the only place the agent loop executes a tool, so the execution
/// contract lives here in one piece: a validated call in, a measured
/// `AssistToolResult` out, with a hard timeout and cooperative cancellation.
/// A timeout (or a thrown error) is reported as a failure — never as success —
/// so the model is told the truth about what happened.
public enum ToolExecutor {

    /// Default per-call limit. A local file scan or a screenshot finishes far
    /// sooner; a stuck call must not stall the whole run.
    public nonisolated static let defaultTimeout: Duration = .seconds(60)

    private enum Race: Sendable {
        case finished(AssistToolResult)
        case failed(String)
        case timedOut
    }

    public nonisolated static func execute(
        tool: any AssistTool,
        arguments: [String: AnyCodableValue],
        context: AssistContext,
        timeout: Duration = defaultTimeout
    ) async -> ToolExecutionOutcome {
        let start = ContinuousClock.now

        let race = await withTaskGroup(of: Race.self) { group -> Race in
            group.addTask {
                do {
                    let input = arguments.mapValues(\.anyValue)
                    return .finished(try await tool.execute(input: input, context: context))
                } catch {
                    return .failed(error.localizedDescription)
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }

        let elapsed = Self.seconds(from: start.duration(to: .now))
        switch race {
        case .finished(let result):
            return ToolExecutionOutcome(result: result, duration: elapsed, timedOut: false)
        case .failed(let message):
            return ToolExecutionOutcome(
                result: .failure(message, code: .executionFailed),
                duration: elapsed,
                timedOut: false
            )
        case .timedOut:
            let limit = Int(seconds(from: timeout).rounded(.up))
            return ToolExecutionOutcome(
                result: .failure(
                    "The action did not finish within \(limit)s and was stopped. Its result is unknown — do not report it as done.",
                    code: .executionFailed
                ),
                duration: elapsed,
                timedOut: true
            )
        }
    }

    private nonisolated static func seconds(from duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
