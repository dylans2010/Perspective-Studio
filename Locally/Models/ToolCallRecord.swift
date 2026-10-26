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

    /// A concise human-readable summary of the tool's primary target or input (e.g. filename, query, symbol).
    public nonisolated var contextualSummary: String? {
        // Query / Search Pattern
        if let query = arguments["query"] ?? arguments["pattern"],
           !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = trimmed.count > 35 ? "\(trimmed.prefix(32))..." : trimmed
            return "'\(preview)'"
        }

        // Code Symbol
        if let symbol = arguments["symbol"] ?? arguments["symbol_name"],
           !symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Terminal Command
        if let command = arguments["command"] ?? arguments["cmd"],
           !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let firstLine = command.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? command
            let preview = firstLine.count > 35 ? "\(firstLine.prefix(32))..." : firstLine
            return preview
        }

        // Arithmetic / Code Expression
        if let expression = arguments["expression"] ?? arguments["expr"],
           !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = trimmed.count > 35 ? "\(trimmed.prefix(32))..." : trimmed
            return preview
        }

        // File or Directory Path
        if let path = arguments["path"]
            ?? arguments["file"]
            ?? arguments["filePath"]
            ?? arguments["file_path"]
            ?? arguments["target_path"]
            ?? arguments["destination"]
            ?? arguments["source"]
            ?? arguments["filename"]
            ?? arguments["dir"]
            ?? arguments["directory"],
           !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            let last = URL(fileURLWithPath: trimmed).lastPathComponent
            return last.isEmpty ? trimmed : last
        }

        // Explicit Operation
        if let operation = arguments["operation"] ?? arguments["op"],
           !operation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return operation.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // System Asset Identifier
        if let assetID = arguments["asset_id"],
           !assetID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return assetID.trimmingCharacters(in: .whitespacesAndNewlines)
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
