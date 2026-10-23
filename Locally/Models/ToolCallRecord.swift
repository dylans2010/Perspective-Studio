import Foundation

public struct ToolCallRecord: Identifiable, Sendable, Equatable {
    public var id: UUID
    public var toolID: String
    public var arguments: [String: String]
    public var result: String?
    public var status: ToolCallStatus
    public var duration: TimeInterval?
    public var startedAt: Date
    public var completedAt: Date?

    public nonisolated init(
        id: UUID = UUID(),
        toolID: String,
        arguments: [String: String] = [:],
        result: String? = nil,
        status: ToolCallStatus = .running,
        duration: TimeInterval? = nil,
        startedAt: Date = .now,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.toolID = toolID
        self.arguments = arguments
        self.result = result
        self.status = status
        self.duration = duration
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    /// Execution duration formatted cleanly (e.g. "0.4s").
    public nonisolated var formattedDuration: String? {
        if let duration {
            return formatSeconds(duration)
        }
        if let completedAt {
            let elapsed = max(0, completedAt.timeIntervalSince(startedAt))
            return formatSeconds(elapsed)
        }
        return nil
    }

    private nonisolated func formatSeconds(_ seconds: TimeInterval) -> String {
        if seconds < 0.05 {
            return "<0.1s"
        }
        return "\(seconds.formatted(.number.precision(.fractionLength(1))))s"
    }
}

extension ToolCallRecord {
    init(step: ToolRunStep, toolID: String = "tool", status: ToolCallStatus = .completed) {
        self.init(
            toolID: toolID,
            arguments: [:],
            result: step.detail,
            status: status
        )
    }

    public init(agentStep: AgentStep) {
        var strArgs: [String: String] = [:]
        if let args = agentStep.toolArguments {
            for (k, v) in args {
                strArgs[k] = "\(v)"
            }
        }
        let status: ToolCallStatus
        if let res = agentStep.toolResult {
            status = res.success ? .completed : .failed(res.error ?? "Execution failed")
        } else if agentStep.kind == .error {
            status = .failed(agentStep.detail ?? "Error")
        } else {
            status = .completed
        }
        self.init(
            id: agentStep.id,
            toolID: agentStep.toolName ?? "tool",
            arguments: strArgs,
            result: agentStep.toolResult?.output ?? agentStep.detail,
            status: status,
            startedAt: agentStep.timestamp
        )
    }
}
