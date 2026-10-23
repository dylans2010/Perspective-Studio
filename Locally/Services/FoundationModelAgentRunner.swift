#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// Runs the agent loop on the built-in Apple model using native tool calling.
///
/// The MLX path teaches the model a `TOOL_CALL {...}` text convention and parses
/// it back out. The system model has first-class tool support, so this runner
/// hands `FoundationModels` real `Tool` values built from `ToolsRegistry` and
/// lets the framework drive the call/observe/answer loop. The System Assets
/// index still goes into the session instructions, and `system_asset_lookup`
/// is one of the offered tools, so the same guidelines are available on demand.
@available(macOS 26.0, *)
@MainActor
enum FoundationModelAgentRunner {
    /// A deliberately small tool set: the on-device model has a ~4K-token
    /// window, so every extra tool schema costs room for the actual task.
    static let offeredToolIDs = [
        "calculator",
        "date_time",
        "hardware_info",
        "model_library",
        "system_asset_lookup",
        "file_read",
        "dir_read",
        "search_text",
        "tree_view"
    ]

    static func run(
        prompt: String,
        workspaceRoot: URL,
        maxTurns: Int,
        dispatchStatus: @escaping @MainActor (AgentHarnessStatus) -> Void,
        addStep: @escaping @MainActor (AgentStep) -> Void,
        onEvent: (@MainActor (AgentHarnessEvent) -> Void)?,
        additionalSystemPrompt: String? = nil
    ) async -> AgentExecutionOutcome {
        let availability = AppleFoundationModel.availability
        guard availability.isAvailable else {
            dispatchStatus(.failed(availability.explanation))
            addStep(AgentStep(kind: .error, title: "Apple Model Unavailable", detail: availability.explanation))
            return AgentExecutionOutcome(answer: "", steps: [], success: false, error: availability.explanation)
        }

        let context = AssistContext(
            workspaceRoot: workspaceRoot,
            safetyLevel: .balanced,
            isAutonomous: true,
            sessionExecutionMode: .autopilot
        )
        let registry = ToolsRegistry.shared

        // Bridge callbacks run off the main actor; they hand events to a
        // Sendable stream that this (main-actor) runner drains into UI updates.
        let (toolEvents, toolEventsContinuation) = AsyncStream<FoundationModelToolEvent>.makeStream()
        let bridgeHandler: @Sendable (FoundationModelToolEvent) -> Void = { event in
            toolEventsContinuation.yield(event)
        }

        let bridges: [any Tool] = offeredToolIDs.compactMap { toolID in
            guard let tool = registry.tool(for: toolID) else { return nil }
            return try? AssistToolBridge(tool: tool, context: context, onEvent: bridgeHandler)
        }

        guard !bridges.isEmpty else {
            let message = "No tools are registered, so agent mode cannot run."
            dispatchStatus(.failed(message))
            addStep(AgentStep(kind: .error, title: "Tools Unavailable", detail: message))
            return AgentExecutionOutcome(answer: "", steps: [], success: false, error: message)
        }

        let collector = AgentStepCollector()
        let record: @MainActor (AgentStep) -> Void = { step in
            collector.add(step)
            addStep(step)
        }

        let eventPump = Task { @MainActor in
            for await event in toolEvents {
                switch event {
                case .started(let toolID, let arguments):
                    dispatchStatus(.callingTool(name: toolID))
                    onEvent?(.toolCallDetected(tool: toolID, arguments: arguments.mapValues { $0 as Any }))
                    record(AgentStep(
                        kind: .toolCall,
                        title: "Tool Call: \(toolID)",
                        detail: arguments
                            .sorted { $0.key < $1.key }
                            .map { "\($0.key): \($0.value)" }
                            .joined(separator: "\n"),
                        toolName: toolID
                    ))
                case .finished(let toolID, let result):
                    dispatchStatus(.toolCompleted(name: toolID))
                    onEvent?(.toolExecutionFinished(tool: toolID, result: result))
                    record(AgentStep(
                        kind: .toolResult,
                        title: result.success ? "Result: \(toolID)" : "Tool Failed: \(toolID)",
                        detail: result.output,
                        toolName: toolID,
                        toolResult: result
                    ))
                }
            }
        }

        record(AgentStep(
            kind: .thought,
            title: "Agent Goal Initialized",
            detail: "Model: \(AppleFoundationModel.displayName)\nTool limit: \(min(maxTurns, offeredToolIDs.count)) turns\nGoal: \(prompt)"
        ))

        dispatchStatus(.thinking)

        let instructions = buildInstructions(toolNames: bridges.map(\.name), additionalSystemPrompt: additionalSystemPrompt)
        let session = LanguageModelSession(tools: bridges, instructions: instructions)

        var answer = ""
        var previous = ""
        do {
            for try await snapshot in session.streamResponse(to: prompt, options: GenerationOptions(temperature: 0.4)) {
                if Task.isCancelled {
                    eventPump.cancel()
                    toolEventsContinuation.finish()
                    dispatchStatus(.idle)
                    return AgentExecutionOutcome(answer: answer, steps: collector.steps, success: false)
                }
                let text = snapshot.content
                let delta = text.hasPrefix(previous) ? String(text.dropFirst(previous.count)) : text
                previous = text
                guard !delta.isEmpty else { continue }
                answer += delta
                onEvent?(.tokenStreamed(delta))
            }
            answer = previous
        } catch {
            eventPump.cancel()
            toolEventsContinuation.finish()
            let message = AppleLanguageModelError.map(error).localizedDescription
            dispatchStatus(.failed(message))
            record(AgentStep(kind: .error, title: "Inference Error", detail: message))
            return AgentExecutionOutcome(answer: answer, steps: collector.steps, success: false, error: message)
        }

        // Let any tool events queued during the final generation reach the UI.
        toolEventsContinuation.finish()
        await eventPump.value

        if answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            answer = "The built-in model finished without producing an answer."
        }

        record(AgentStep(kind: .finalAnswer, title: "Final Answer", detail: answer))
        dispatchStatus(.finished)
        return AgentExecutionOutcome(answer: answer, steps: collector.steps, success: true)
    }

    private static func buildInstructions(toolNames: [String], additionalSystemPrompt: String? = nil) -> String {
        let assetsIndex = SystemAssetsManager.shared.generatePromptIndex()

        var instructions = """
        # Locally Agent Runtime

        You are an autonomous assistant running privately on this Mac with Apple Intelligence.
        You have these tools: \(toolNames.joined(separator: ", ")).

        ## How to work
        1. Use a tool whenever the task needs real files, device facts, arithmetic, or guidelines. Do not guess file contents or system details.
        2. Read the tool result, then either call another tool or give the final answer.
        3. When a system guideline would help, retrieve it with the system_asset_lookup tool instead of inventing rules.

        \(assetsIndex)

        ## Response style
        - Lead with the answer.
        - Use Markdown headings, lists and fenced code blocks when they help.
        - Keep it short enough to fit an on-device model's context.
        """

        // Custom system prompts + skills + thinking format, assembled by
        // ModelContextBuilder at the call site. The on-device context is
        // small, so callers keep this compact — but it must be present at
        // all, or the model (correctly, from its view) denies having them.
        if let additionalSystemPrompt,
           !additionalSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            instructions += "\n\n" + additionalSystemPrompt
        }
        return instructions
    }
}

/// Main-actor step buffer so the event pump and the runner can both contribute
/// to the trace the UI shows.
@available(macOS 26.0, *)
@MainActor
private final class AgentStepCollector {
    private(set) var steps: [AgentStep] = []

    func add(_ step: AgentStep) {
        steps.append(step)
    }
}

#endif
