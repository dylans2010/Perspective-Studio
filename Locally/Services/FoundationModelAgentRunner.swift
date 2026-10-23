#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// Runs the agent loop on the built-in Apple model using native tool calling.
///
/// The MLX path teaches the model a `TOOL_CALL {...}` text convention and parses
/// it back out. The system model has first-class tool support, so this runner
/// hands `FoundationModels` real `Tool` values built from `ToolsRegistry` and
/// lets the framework drive the call/observe/answer loop. The session
/// instructions carry only the context index's counts-only directory;
/// full guidelines stay retrievable on demand through the offered lookup
/// tools (`system_asset_lookup` and `context_index_search`).
@available(macOS 26.0, *)
@MainActor
enum FoundationModelAgentRunner {
    /// Candidate base pool for the scored selection below. The on-device
    /// model has a ~4K-token window, so every offered native tool costs
    /// instruction tokens: a run no longer offers this whole pool — it
    /// offers the core retrieval tools plus the pool members the local
    /// index scores as relevant to the run's prompt, capped at
    /// `maxOfferedTools` in total.
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

    /// Computer Use candidate subset for the on-device model when the
    /// user has turned Computer Use on (observe, act, verify), sized for
    /// the small context window. These join the scored candidate pool —
    /// they are offered only when the index scores them relevant to the
    /// run's prompt, and never at all while Computer Use is off. The MLX
    /// path through the Antigravity loop offers the full suite; this
    /// subset is what makes Computer Use *reachable at all* on the
    /// Apple-model path, where it previously was not offered in any form.
    static let computerUseToolIDs = [
        "computer_get_permissions",
        "computer_screenshot",
        "computer_read_screen_text",
        "computer_get_accessibility_tree",
        "computer_find_ui_element",
        "computer_mouse_click",
        "computer_keyboard_type",
        "computer_keyboard_shortcut",
        "computer_open_application",
        "computer_verify_state"
    ]

    /// Hard cap on the tools one run offers the on-device model,
    /// core tools included. On a ~4K-token window, a fixed dozen-plus
    /// tool schemas crowded out the task itself; the scored selection
    /// keeps the total at or below this cap.
    static let maxOfferedTools = 12

    /// The tools one run actually offers, query-scored by the context
    /// index. Always offered: the core retrieval tools
    /// (`context_index_search`, `system_asset_lookup`) — the model must
    /// always be able to retrieve index entries on demand, since prompts
    /// no longer carry them. With a project active, `project_memory`
    /// (project runs must be able to read/write project memory) and
    /// `tree_view` (the Project Tool Mandate's grounding exploration)
    /// are always offered too, regardless of score. The remaining slots
    /// go to the candidate pool (`offeredToolIDs`, plus the Computer Use
    /// subset when Computer Use is enabled) scored against the run's
    /// prompt: score descending, index order breaking ties, zero-score
    /// candidates not offered.
    static func runToolIDs(query: String = "", projectID: UUID?, computerUseEnabled: Bool) -> [String] {
        let toolEntries = ContextIndexManager.liveEntries(mode: .agent).filter { $0.kind == .tool }
        return selectToolIDs(
            query: query,
            toolEntries: toolEntries,
            projectActive: projectID != nil,
            computerUseEnabled: computerUseEnabled
        )
    }

    /// The pure selection behind `runToolIDs` — deterministic, and
    /// testable over fixture entries: mandatory tools first (fixed
    /// order), then scored candidates until `maxOfferedTools` is hit.
    static func selectToolIDs(
        query: String,
        toolEntries: [ContextIndexManager.Entry],
        projectActive: Bool,
        computerUseEnabled: Bool
    ) -> [String] {
        var selected: [String] = ["context_index_search", "system_asset_lookup"]
        if projectActive {
            for id in ["project_memory", "tree_view"] where !selected.contains(id) {
                selected.append(id)
            }
        }

        var candidateIDs = offeredToolIDs
        if computerUseEnabled {
            candidateIDs += computerUseToolIDs
        }

        let queryTokens = ContextIndexManager.tokenize(query)
        let scored: [(id: String, score: Int, order: Int)] = candidateIDs.compactMap { id in
            guard !selected.contains(id),
                  let entry = toolEntries.first(where: { $0.id == "tool:\(id)" }) else { return nil }
            let score = ContextIndexManager.score(entry: entry, queryTokens: queryTokens)
            return score > 0 ? (id: id, score: score, order: entry.order) : nil
        }
        .sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }

        for candidate in scored {
            if selected.count >= maxOfferedTools { break }
            selected.append(candidate.id)
        }
        return selected
    }

    static func run(
        prompt: String,
        workspaceRoot: URL,
        projectID: UUID? = nil,
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
            agentProjectID: projectID,
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

        let runToolIDs = Self.runToolIDs(query: prompt, projectID: projectID, computerUseEnabled: ComputerUseSettings.isEnabled)
        let bridges: [any Tool] = runToolIDs.compactMap { toolID in
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
                        title: ToolNameFormatter.format(toolID),
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
                        title: result.success ? ToolNameFormatter.completedTitle(for: toolID) : "\(ToolNameFormatter.format(toolID)) Failed",
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
            detail: "Model: \(AppleFoundationModel.displayName)\nTools offered: \(runToolIDs.count)\nGoal: \(prompt)"
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

        // Project Tool Mandate enforcement. Native tool calling cannot be
        // forced into a required-tool mode, so when a project run
        // finishes without the model having called a single tool, the
        // runner itself performs the opening exploration through the
        // registry (a real tool execution, recorded like any other) and
        // asks the model for a final answer grounded in that result.
        if let projectID,
           let project = AgentProjectsStore.shared.project(id: projectID),
           AgentToolPolicy.mustRejectFinalAnswer(
               toolCallsExecuted: collector.steps.filter { $0.kind == .toolCall }.count,
               projectActive: true,
               requireToolUse: project.requireToolUse,
               rejectionsUsed: 0
           ) {
            record(AgentStep(
                kind: .thought,
                title: "Project Tool Mandate",
                detail: "The model answered about \"\(project.name)\" without using any tools. Running the project exploration now and grounding the final answer in it."
            ))
            dispatchStatus(.callingTool(name: "tree_view"))
            onEvent?(.toolCallDetected(tool: "tree_view", arguments: ["path": "."]))
            let exploration: AssistToolResult
            do {
                exploration = try await registry.execute(
                    toolId: "tree_view",
                    arguments: ["path": "."],
                    context: context
                )
            } catch {
                exploration = .failure(error.localizedDescription, code: .executionFailed)
            }
            dispatchStatus(.toolCompleted(name: "tree_view"))
            onEvent?(.toolExecutionFinished(tool: "tree_view", result: exploration))
            record(AgentStep(
                kind: .toolResult,
                title: exploration.success ? ToolNameFormatter.completedTitle(for: "tree_view") : "\(ToolNameFormatter.format("tree_view")) Failed",
                detail: exploration.output,
                toolName: "tree_view",
                toolResult: exploration
            ))

            if exploration.success {
                // The tree itself rides in the result's data; `output`
                // alone is only the tool's one-line summary.
                let treeText = exploration.data?["tree"] ?? exploration.output
                let groundingPrompt = """
                You answered the user's request about the project "\(project.name)" without inspecting it. That draft is discarded. Here is the project's actual structure, from a real inspection just now:

                \(treeText)

                Now answer the original request — "\(prompt)" — grounded ONLY in what this inspection and any further tool calls show you. Call more tools if you need file contents before answering.
                """
                var groundedPrevious = ""
                var groundedAnswer = ""
                do {
                    for try await snapshot in session.streamResponse(to: groundingPrompt, options: GenerationOptions(temperature: 0.4)) {
                        if Task.isCancelled { break }
                        let text = snapshot.content
                        let delta = text.hasPrefix(groundedPrevious) ? String(text.dropFirst(groundedPrevious.count)) : text
                        groundedPrevious = text
                        guard !delta.isEmpty else { continue }
                        groundedAnswer += delta
                        onEvent?(.tokenStreamed(delta))
                    }
                    if !groundedPrevious.isEmpty {
                        answer = groundedPrevious
                    }
                } catch {
                    // Keep the original answer if the grounded retry fails;
                    // the exploration steps above still document the run.
                    _ = groundedAnswer
                }
            }
        }

        // Native tool calling never puts invocation syntax in the text,
        // but the answer still passes the same display sanitizer as every
        // other path, so no raw tool identifier can reach the user.
        answer = ToolInvocationSanitizer.displayText(for: answer, knownToolIDs: registry.allToolIDs)
        if answer.isEmpty {
            answer = "The built-in model finished without producing an answer."
        }

        record(AgentStep(kind: .finalAnswer, title: "Final Answer", detail: answer))
        dispatchStatus(.finished)
        return AgentExecutionOutcome(answer: answer, steps: collector.steps, success: true)
    }

    private static func buildInstructions(toolNames: [String], additionalSystemPrompt: String? = nil) -> String {
        // Counts-only directory from the context index — never the full
        // asset index or any catalog. Full entries are retrieved on
        // demand through the offered lookup tools.
        let directory = ContextIndexManager.directoryText(mode: .agent)
        let sdkLine = AntigravitySDKBundle.agentModeContextLine(status: AntigravitySDKBundle.status())
        let indexLine = "Models, tools, and system prompts here are Locally's own, served from the local context index — the bundled SDK provides only the agent-loop design, never models, tools, or prompts."
        let computerLine = ComputerUseSettings.isEnabled
            ? "Computer Use is ON and its desktop tools are among the tools offered to you: observe the screen first, act once, then verify."
            : "Computer Use is OFF; no desktop tools are offered in this run."

        var instructions = """
        # Locally Agent Runtime

        You are an autonomous assistant running privately on this Mac with Apple Intelligence.
        You have these tools: \(toolNames.joined(separator: ", ")).
        \(sdkLine)
        \(indexLine)
        \(computerLine)

        ## How to work
        1. Use a tool whenever the task needs real files, device facts, arithmetic, or guidelines. Do not guess file contents or system details.
        2. Read the tool result, then either call another tool or give the final answer.
        3. When a system guideline would help, retrieve it with the system asset lookup instead of inventing rules.
        4. Never mention a tool's name or id in your answer. The app shows your tool activity in its own cards; in your text, describe actions and findings in plain language ("I read the file", "I searched the project").
        5. If a project is active (its context appears below), you MUST call tools for it: explore the project first, ground every claim in a result from this run, and record durable facts in the project's memory. A tool-less answer about a project is rejected by the runtime.

        \(directory)

        ## Response style
        - Lead with the answer.
        - Use Markdown headings, lists and fenced code blocks when they help.
        - Keep it short enough to fit an on-device model's context.
        """

        // Retrieved custom-prompt/skill/memory excerpts + thinking
        // format, assembled by ModelContextBuilder at the call site from
        // the context index. The on-device context is small, so the
        // bundle is budgeted — but it must be present at all, or the
        // model (correctly, from its view) denies having them.
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
