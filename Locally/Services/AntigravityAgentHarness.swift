import Foundation
import Observation

// MARK: - Agent Harness Status

public enum AgentHarnessStatus: Sendable, Equatable {
    case idle
    case thinking
    case callingTool(name: String)
    case toolCompleted(name: String)
    case finished
    case failed(String)

    public var displayText: String {
        switch self {
        case .idle:
            return "Idle"
        case .thinking:
            return "Reasoning..."
        case .callingTool(let name):
            return "Calling \(name)..."
        case .toolCompleted(let name):
            return "Completed \(name)"
        case .finished:
            return "Completed"
        case .failed(let error):
            return "Error: \(error)"
        }
    }
}

// MARK: - Agent Step Trace

public struct AgentStep: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let kind: StepKind
    public let title: String
    public let detail: String?
    public let rawPayload: String?
    public let toolName: String?
    public let toolArguments: [String: Any]?
    public let toolResult: AssistToolResult?

    public enum StepKind: String, Sendable, Codable {
        case thought
        case toolCall
        case toolResult
        case finalAnswer
        case error
    }

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date.now,
        kind: StepKind,
        title: String,
        detail: String? = nil,
        rawPayload: String? = nil,
        toolName: String? = nil,
        toolArguments: [String: Any]? = nil,
        toolResult: AssistToolResult? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.title = title
        self.detail = detail
        self.rawPayload = rawPayload
        self.toolName = toolName
        self.toolArguments = toolArguments
        self.toolResult = toolResult
    }
}

// MARK: - Agent Harness Events

public enum AgentHarnessEvent: Sendable {
    case statusChanged(AgentHarnessStatus)
    case stepAdded(AgentStep)
    case tokenStreamed(String)
    case toolCallDetected(tool: String, arguments: [String: Any])
    case toolExecutionStarted(tool: String)
    case toolExecutionFinished(tool: String, result: AssistToolResult)
    case completed(answer: String, steps: [AgentStep])
    case failed(String)
}

// MARK: - Agent Execution Outcome

public struct AgentExecutionOutcome: Sendable {
    public let answer: String
    public let steps: [AgentStep]
    public let success: Bool
    public let error: String?

    public init(
        answer: String,
        steps: [AgentStep],
        success: Bool,
        error: String? = nil
    ) {
        self.answer = answer
        self.steps = steps
        self.success = success
        self.error = error
    }
}

// MARK: - Antigravity Agent Harness

/// Pure native implementation of the Antigravity Agent SDK harness.
///
/// Principles:
/// - Zero bundled cloud models — runs strictly on the user's locally installed models.
/// - Zero hardcoded external tools — uses dynamically registered tools from `ToolsRegistry`.
/// - Indexes guidelines from `SystemAssetsManager.shared.generatePromptIndex()`.
/// - Orchestrates the multi-turn agent loop: Thought -> Tool Call -> Observation -> Synthesis.
@Observable
@MainActor
public final class AntigravityAgentHarness {
    public static let shared = AntigravityAgentHarness()

    public private(set) var status: AgentHarnessStatus = .idle
    public private(set) var steps: [AgentStep] = []
    public private(set) var currentThought: String = ""
    public private(set) var isRunning: Bool = false
    public private(set) var activeToolName: String? = nil

    private var activeTask: Task<Void, Never>?

    public init() {}

    /// Cancels any in-flight agent execution.
    public func cancel() {
        activeTask?.cancel()
        activeTask = nil
        if isRunning {
            status = .idle
            isRunning = false
            activeToolName = nil
        }
    }

    /// Executes the Antigravity Agent Loop autonomously on the user's local model.
    func run(
        prompt: String,
        modelID: String? = nil,
        workspaceRoot: URL = URL.documentsDirectory,
        maxTurns: Int = 10,
        backend: (any InferenceBackend)? = nil,
        additionalSystemPrompt: String? = nil,
        onEvent: (@MainActor (AgentHarnessEvent) -> Void)? = nil
    ) async -> AgentExecutionOutcome {
        cancel()
        isRunning = true
        steps = []
        currentThought = ""
        status = .thinking
        activeToolName = nil

        let dispatchStatus: @MainActor (AgentHarnessStatus) -> Void = { [weak self] newStatus in
            guard let self else { return }
            self.status = newStatus
            onEvent?(.statusChanged(newStatus))
        }

        let addStep: @MainActor (AgentStep) -> Void = { [weak self] step in
            guard let self else { return }
            self.steps.append(step)
            onEvent?(.stepAdded(step))
        }

        defer {
            self.isRunning = false
            self.activeToolName = nil
        }

        let selectedBackend = backend ?? InferenceBackends.default

        // The built-in Apple model exposes native tool calling, so it runs
        // through its own loop instead of the TOOL_CALL text protocol below.
        if #available(macOS 26.0, *), selectedBackend.backendID == AppleFoundationModel.backendID {
            return await FoundationModelAgentRunner.run(
                prompt: prompt,
                workspaceRoot: workspaceRoot,
                maxTurns: maxTurns,
                dispatchStatus: dispatchStatus,
                addStep: addStep,
                onEvent: onEvent,
                additionalSystemPrompt: additionalSystemPrompt
            )
        }

        // 1. Resolve and ensure local model is ready
        let targetModelID: String
        if let explicit = modelID, !explicit.isEmpty {
            targetModelID = explicit
        } else if let loaded = await selectedBackend.currentlyLoadedModelID(), !loaded.isEmpty {
            targetModelID = loaded
        } else if let firstCached = HFHubCache.cachedModelIDs().first {
            targetModelID = firstCached
        } else {
            let msg = "No local models are installed. Please download a model from the Models catalog to use Agent Mode."
            dispatchStatus(.failed(msg))
            let errorStep = AgentStep(kind: .error, title: "Model Missing", detail: msg)
            addStep(errorStep)
            return AgentExecutionOutcome(answer: "", steps: steps, success: false, error: msg)
        }

        // Load the model if needed
        do {
            let parts = targetModelID.components(separatedBy: "/")
            let installed = InstalledModel(
                id: targetModelID,
                displayName: parts.last ?? targetModelID,
                author: parts.count > 1 ? parts.first ?? "local" : "local",
                isVisual: false
            )
            _ = try await selectedBackend.load(model: installed)
        } catch {
            let msg = "Failed to load model '\(targetModelID)': \(error.localizedDescription)"
            dispatchStatus(.failed(msg))
            let errorStep = AgentStep(kind: .error, title: "Model Load Error", detail: msg)
            addStep(errorStep)
            return AgentExecutionOutcome(answer: "", steps: steps, success: false, error: msg)
        }

        // 2. Prepare context & system instructions
        let assistContext = AssistContext(
            sessionId: UUID(),
            workspaceRoot: workspaceRoot,
            safetyLevel: .balanced,
            isAutonomous: true,
            sessionExecutionMode: .autopilot
        )

        let systemPrompt = buildSystemPrompt(context: assistContext, additionalSystemPrompt: additionalSystemPrompt)

        // Initial goal step
        addStep(AgentStep(
            kind: .thought,
            title: "Agent Goal Initialized",
            detail: "Target Model: \(targetModelID)\nGoal: \(prompt)"
        ))

        var conversationTurns: [Turn] = [
            Turn(role: "user", content: prompt)
        ]

        var finalAnswer: String = ""
        var turnCount = 0

        // 3. Multi-turn Agent Loop
        while turnCount < maxTurns && !Task.isCancelled {
            turnCount += 1
            dispatchStatus(.thinking)
            currentThought = ""

            let fullPrompt = assemblePrompt(turns: conversationTurns)

            var turnResponse = ""
            do {
                let stream = try selectedBackend.stream(prompt: fullPrompt, systemPrompt: systemPrompt)
                for try await event in stream {
                    if Task.isCancelled { break }
                    switch event {
                    case .token(let token):
                        turnResponse += token
                        self.currentThought = turnResponse
                        onEvent?(.tokenStreamed(token))
                    case .finished:
                        break
                    }
                }
            } catch {
                let msg = "Inference generation error: \(error.localizedDescription)"
                dispatchStatus(.failed(msg))
                let errStep = AgentStep(kind: .error, title: "Inference Error", detail: msg)
                addStep(errStep)
                return AgentExecutionOutcome(answer: finalAnswer, steps: steps, success: false, error: msg)
            }

            if Task.isCancelled {
                dispatchStatus(.idle)
                return AgentExecutionOutcome(answer: "Execution was cancelled.", steps: steps, success: false)
            }

            // 4. Parse response for tool calls
            if let toolCall = Self.parseToolCall(in: turnResponse) {
                let toolId = toolCall.toolId
                let args = toolCall.arguments

                self.activeToolName = toolId
                dispatchStatus(.callingTool(name: toolId))
                onEvent?(.toolCallDetected(tool: toolId, arguments: args))
                onEvent?(.toolExecutionStarted(tool: toolId))

                let callStep = AgentStep(
                    kind: .toolCall,
                    title: "Tool Call: \(toolId)",
                    detail: formatArgumentsPreview(args),
                    rawPayload: turnResponse,
                    toolName: toolId,
                    toolArguments: args
                )
                addStep(callStep)

                // Execute via ToolsRegistry
                let result: AssistToolResult
                do {
                    result = try await ToolsRegistry.shared.execute(
                        toolId: toolId,
                        arguments: args,
                        context: assistContext
                    )
                } catch {
                    result = .failure(error.localizedDescription, code: .executionFailed)
                }

                dispatchStatus(.toolCompleted(name: toolId))
                onEvent?(.toolExecutionFinished(tool: toolId, result: result))

                let resultStep = AgentStep(
                    kind: .toolResult,
                    title: result.success ? "Result: \(toolId)" : "Tool Failed: \(toolId)",
                    detail: result.output,
                    toolName: toolId,
                    toolResult: result
                )
                addStep(resultStep)

                // Feed tool result back into conversation turns
                conversationTurns.append(Turn(role: "assistant", content: turnResponse))
                conversationTurns.append(Turn(
                    role: "user",
                    content: "TOOL_RESULT [\(toolId)]:\n\(result.output)\n\nAnalyze this tool output and proceed to the next step, or provide the final answer if complete."
                ))

                self.activeToolName = nil
            } else {
                // Model provided final synthesized answer (or direct response)
                finalAnswer = cleanFinalAnswer(turnResponse)
                let finalStep = AgentStep(
                    kind: .finalAnswer,
                    title: "Final Answer",
                    detail: finalAnswer
                )
                addStep(finalStep)
                dispatchStatus(.finished)
                onEvent?(.completed(answer: finalAnswer, steps: steps))
                return AgentExecutionOutcome(answer: finalAnswer, steps: steps, success: true)
            }
        }

        // Loop concluded without direct answer
        if finalAnswer.isEmpty {
            finalAnswer = currentThought.isEmpty ? "Agent completed \(turnCount) turns." : currentThought
            addStep(AgentStep(kind: .finalAnswer, title: "Synthesized Output", detail: finalAnswer))
        }

        dispatchStatus(.finished)
        onEvent?(.completed(answer: finalAnswer, steps: steps))
        return AgentExecutionOutcome(answer: finalAnswer, steps: steps, success: true)
    }

    // MARK: - Prompt Construction

    private func buildSystemPrompt(context: AssistContext, additionalSystemPrompt: String? = nil) -> String {
        let assetsIndex = SystemAssetsManager.shared.generatePromptIndex()
        let toolsSchema = ToolsRegistry.shared.schemaDescriptions()

        var prompt = """
        # Antigravity Agent Runtime

        You are an autonomous AI agent running locally and privately on macOS via Locally.
        Your goal is to solve the user's objective thoroughly, safely, and concisely using the tools provided.

        ## Core Operational Guidelines:
        1. When a task requires external data, system verification, or computation, use the available tools.
        2. To call a tool, output ONLY a single line in this exact JSON format:
           TOOL_CALL {"tool": "<tool_id>", "arguments": { ... }}
        3. Do not include extra conversational text on the line of a TOOL_CALL.
        4. When the tool returns its result, analyze the observations and either call the next tool or give the final answer.
        5. When you have gathered enough information or the task is finished, respond directly to the user with a comprehensive, well-structured Markdown response (no tool call syntax).

        \(assetsIndex)

        \(toolsSchema)

        ## Response Style:
        - Lead directly with facts, code, or answers. Avoid fluff and filler.
        - Structure your final response with rich Markdown headers, bullet points, and code fences.
        """

        // The caller's context — custom system prompts, skills, and the
        // <thinking> format instruction assembled by ModelContextBuilder.
        // This is the part Agent mode never received before this parameter
        // existed, so the agent denied having any of it.
        if let additionalSystemPrompt,
           !additionalSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "\n\n" + additionalSystemPrompt
        }
        return prompt
    }

    private struct Turn {
        let role: String
        let content: String
    }

    private func assemblePrompt(turns: [Turn]) -> String {
        var lines: [String] = []
        for turn in turns {
            switch turn.role {
            case "user":
                lines.append("User: \(turn.content)")
            case "assistant":
                lines.append("Assistant: \(turn.content)")
            default:
                lines.append("\(turn.role): \(turn.content)")
            }
        }
        lines.append("Assistant:")
        return lines.joined(separator: "\n\n")
    }

    private func cleanFinalAnswer(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("Assistant:") {
            cleaned = String(cleaned.dropFirst("Assistant:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }

    private func formatArgumentsPreview(_ args: [String: Any]) -> String {
        guard !args.isEmpty else { return "No arguments" }
        if let data = try? JSONSerialization.data(withJSONObject: args, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "\(args)"
    }

    // MARK: - Tool Call Parser

    /// Extracts tool calls from model output in either standard `TOOL_CALL` syntax or JSON payloads.
    public nonisolated static func parseToolCall(in text: String) -> (toolId: String, arguments: [String: Any])? {
        // 1. Explicit TOOL_CALL token
        if let marker = text.range(of: "TOOL_CALL") {
            let remainder = text[marker.upperBound...]
            if let start = remainder.firstIndex(of: "{"),
               let data = balancedJSON(in: remainder[start...]),
               let parsed = decodeToolCallData(data) {
                return parsed
            }
        }

        // 2. Markdown fenced code block containing a tool call
        if let blockStart = text.range(of: "```json"),
           let blockEnd = text.range(of: "```", range: blockStart.upperBound..<text.endIndex) {
            let jsonSlice = text[blockStart.upperBound..<blockEnd.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = jsonSlice.data(using: .utf8),
               let parsed = decodeToolCallData(data) {
                return parsed
            }
        }

        // 3. Raw JSON object containing "tool" and "arguments"
        if let firstBrace = text.firstIndex(of: "{"),
           let data = balancedJSON(in: text[firstBrace...]),
           let parsed = decodeToolCallData(data) {
            return parsed
        }

        return nil
    }

    private nonisolated static func decodeToolCallData(_ data: Data) -> (toolId: String, arguments: [String: Any])? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }

        // Support { "tool": "..." } or { "name": "..." }
        guard let toolId = (json["tool"] ?? json["name"] ?? json["function"]) as? String,
              !toolId.isEmpty else {
            return nil
        }

        // Support { "arguments": { ... } } or { "parameters": { ... } }
        let rawArgs = (json["arguments"] ?? json["parameters"] ?? json["input"]) as? [String: Any] ?? [:]
        return (toolId, rawArgs)
    }

    /// Finds the balanced `{...}` JSON substring at the start of `text`.
    private nonisolated static func balancedJSON(in text: Substring) -> Data? {
        var depth = 0
        var inString = false
        var escaped = false

        for (offset, char) in text.enumerated() {
            if escaped {
                escaped = false
                continue
            }
            if char == "\\" && inString {
                escaped = true
                continue
            }
            if char == "\"" {
                inString.toggle()
                continue
            }
            if inString { continue }

            if char == "{" {
                depth += 1
            } else if char == "}" {
                depth -= 1
                if depth == 0 {
                    let endIndex = text.index(text.startIndex, offsetBy: offset + 1)
                    return Data(text[text.startIndex..<endIndex].utf8)
                }
            }
        }
        return nil
    }
}
