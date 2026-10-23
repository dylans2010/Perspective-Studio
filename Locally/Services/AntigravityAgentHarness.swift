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
            // Human action names only — raw tool ids are private protocol
            // tokens and never reach the screen.
            return "\(ToolNameFormatter.format(name))..."
        case .toolCompleted(let name):
            return ToolNameFormatter.completedTitle(for: name)
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
    /// The identifier of the tool-call record this step belongs to, so a call
    /// and its result can be tied together even when the model makes several
    /// calls with the same tool in one run.
    public let callID: String?

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
        toolResult: AssistToolResult? = nil,
        callID: String? = nil
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
        self.callID = callID
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
    /// The structured record for one call, updated in place (running →
    /// completed/failed) so UI surfaces never have to infer status from text.
    case toolCallRecordUpdated(ToolCallRecord)
    case completed(answer: String, steps: [AgentStep])
    case failed(String)
}

// MARK: - Agent Execution Outcome

public struct AgentExecutionOutcome: Sendable {
    public let answer: String
    public let steps: [AgentStep]
    public let success: Bool
    public let error: String?
    /// The model's reasoning across the run, split out of its turns by
    /// `AntigravityLoopEngine.splitThinking`. Callers re-attach it to the
    /// persisted message inside `<thinking>` tags so the message row
    /// renders it in `ThinkingModelUI` — as thinking, never as answer.
    public let thinking: String?

    public init(
        answer: String,
        steps: [AgentStep],
        success: Bool,
        error: String? = nil,
        thinking: String? = nil
    ) {
        self.answer = answer
        self.steps = steps
        self.success = success
        self.error = error
        self.thinking = thinking
    }
}

// MARK: - Antigravity Agent Harness

/// The Agent-mode harness, built on the bundled Antigravity SDK's loop
/// layer (`AntigravityLoopEngine`; the upstream SDK ships inside the app —
/// see `AntigravitySDKBundle`).
///
/// Principles:
/// - The SDK contributes the loop ONLY: no SDK models and no SDK tools are
///   bundled or used. Models are the user's locally installed ones
///   (`InferenceBackend`); tools are Locally's own (`ToolsRegistry`).
/// - Context comes from `ContextIndexManager`: a counts-only directory
///   plus the tool schemas the local retriever selected for the run's
///   prompt (core tools first, inside a fixed sub-budget) — never the
///   full schema dump or the full asset index. The model retrieves more
///   from the index on demand during the run.
/// - Orchestrates the multi-turn agent loop: Thought -> Tool Call -> Observation -> Synthesis.
/// - Tool invocations are private plumbing: they are consumed by the loop
///   and shown to the user only as tool cards, never as message text.
@Observable
@MainActor
public final class AntigravityAgentHarness {
    public static let shared = AntigravityAgentHarness()

    public private(set) var status: AgentHarnessStatus = .idle
    public private(set) var steps: [AgentStep] = []
    public private(set) var currentThought: String = ""
    public private(set) var isRunning: Bool = false
    public private(set) var activeToolName: String? = nil
    /// Structured records of every tool call this run attempted to execute:
    /// canonical tool id, validated arguments, status, real result, duration.
    /// Rejected calls never appear here — nothing was executed for them.
    public private(set) var toolCallRecords: [ToolCallRecord] = []

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
    ///
    /// The loop itself is `AntigravityLoopEngine` (the bundled Antigravity
    /// SDK's loop layer): it classifies turns, builds observation prompts,
    /// and cleans final answers. This harness supplies what the loop must
    /// never own — the model (`InferenceBackend`) and the tools
    /// (`ToolsRegistry`).
    func run(
        prompt: String,
        modelID: String? = nil,
        workspaceRoot: URL = URL.documentsDirectory,
        projectID: UUID? = nil,
        maxTurns: Int = 10,
        maxToolExecutions: Int = AntigravityLoopEngine.maxToolExecutionsPerRun,
        toolTimeout: Duration = ToolExecutor.defaultTimeout,
        backend: (any InferenceBackend)? = nil,
        additionalSystemPrompt: String? = nil,
        onEvent: (@MainActor (AgentHarnessEvent) -> Void)? = nil
    ) async -> AgentExecutionOutcome {
        cancel()
        isRunning = true
        steps = []
        toolCallRecords = []
        currentThought = ""
        status = .thinking
        activeToolName = nil
        let turnBudget = max(1, min(maxTurns, 32))
        let executionBudget = max(1, maxToolExecutions)

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

        // The registry snapshot this run validates every requested call
        // against. Taken once, at the start: the registry stays the source of
        // truth, and the loop never invents a tool or an argument key.
        let catalog = ToolCatalog(tools: ToolsRegistry.shared.allTools)
        let knownToolIDs = catalog.ids

        // 0. Verify the bundled Antigravity SDK before anything else.
        // Agent mode runs on this SDK's loop in EVERY configuration (the
        // MLX text-protocol loop below and the Apple model's native loop),
        // so its state is established up front, shown in the run trace,
        // and injected into the system prompt — the model can always use
        // the loop, and can never be left believing it is (or isn't)
        // there. A missing/unverifiable bundle does not block the run:
        // the loop engine is native Swift, and the trace + prompt say
        // plainly that the bundled SDK reported a problem.
        let sdkStatus = AntigravitySDKBundle.status()
        addStep(AgentStep(
            kind: .thought,
            title: sdkStatus.isUsable ? "Agent Engine Ready" : "Agent Engine Warning",
            detail: sdkStatus.summary + (sdkStatus.issues.isEmpty ? "" : "\n" + sdkStatus.issues.joined(separator: "\n"))
        ))

        // The active project (if any) and its tool-use requirement, which
        // gate final answers below via AgentToolPolicy.
        let activeProject = projectID.flatMap { AgentProjectsStore.shared.project(id: $0) }
        let requireProjectTools = activeProject?.requireToolUse ?? true

        // The router's classification of this turn. Conversational and
        // direct turns do NOT enter the tool loop below: they are
        // answered with a single direct generation (the MLX path after
        // model load; the Apple-model path inside its runner). A direct
        // turn whose model output turns out to contain a genuine tool
        // call escalates into the loop — the router gates machinery,
        // never capability.
        let intent = ConversationRouter.intent(for: prompt)

        // The built-in Apple model exposes native tool calling, so it runs
        // through its own loop instead of the TOOL_CALL text protocol below.
        if #available(macOS 26.0, *), selectedBackend.backendID == AppleFoundationModel.backendID {
            return await FoundationModelAgentRunner.run(
                prompt: prompt,
                workspaceRoot: workspaceRoot,
                projectID: projectID,
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

        // 1b. Conversational / direct turns: one direct generation, no
        // tool schemas, no loop, no mandate. The system prompt is the
        // caller's ModelContextBuilder output (which already carries
        // the conversation-first core and, for conversational turns, no
        // directory and no retrieved machinery).
        let directSystemPrompt: String = {
            if let additionalSystemPrompt, !additionalSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return additionalSystemPrompt
            }
            return ModelContextBuilder.build(ModelContextBuilder.Input(isAgentMode: true, intent: intent))
        }()

        /// One direct generation. Returns the cleaned answer, its
        /// split-out thinking, and whether the model tried to call a
        /// tool instead of answering.
        func directTurn(extraInstruction: String? = nil) async -> (answer: String, thinking: String?, wantsTool: Bool) {
            var text = ""
            do {
                let stream = try selectedBackend.stream(
                    prompt: prompt,
                    systemPrompt: extraInstruction.map { directSystemPrompt + "\n\n" + $0 } ?? directSystemPrompt
                )
                for try await event in stream {
                    if Task.isCancelled { break }
                    if case .token(let token) = event {
                        text += token
                        onEvent?(.tokenStreamed(token))
                    }
                }
            } catch {
                return ("", nil, false)
            }
            let split = AntigravityLoopEngine.splitThinking(from: text)
            let decision = AntigravityLoopEngine.decide(turnText: split.answer, catalog: catalog)
            if decision.isToolAttempt {
                return ("", split.thinking, true)
            }
            let cleaned = AntigravityLoopEngine.cleanFinalAnswer(split.answer, knownToolIDs: knownToolIDs)
            return (cleaned, split.thinking, false)
        }

        if intent != .task {
            var direct = await directTurn()
            if intent == .conversational && (direct.wantsTool || direct.answer.isEmpty) && !Task.isCancelled {
                // One retry with the plain-text requirement stated again.
                // Never a hardcoded reply: if the model still cannot
                // answer conversationally, the failure is reported as one.
                direct = await directTurn(extraInstruction: "[This Turn — retry]: Answer in plain conversational text only. Do not call, mention, or describe any tool, skill, or instruction.")
            }

            if intent == .direct && direct.wantsTool {
                // Escalation: the question genuinely needs a tool after
                // all — fall through to the full loop below.
            } else {
                let answer = direct.answer
                addStep(AgentStep(kind: .finalAnswer, title: "Final Answer", detail: answer))
                dispatchStatus(.finished)
                onEvent?(.completed(answer: answer, steps: steps))
                return AgentExecutionOutcome(
                    answer: answer,
                    steps: steps,
                    success: !answer.isEmpty,
                    error: answer.isEmpty ? "The model did not produce a reply for that message." : nil,
                    thinking: direct.thinking
                )
            }
        }

        // 2. Prepare context & system instructions
        let assistContext = AssistContext(
            sessionId: UUID(),
            workspaceRoot: workspaceRoot,
            agentProjectID: projectID,
            safetyLevel: .balanced,
            isAutonomous: true,
            sessionExecutionMode: .autopilot
        )

        let systemPrompt = buildSystemPrompt(
            query: prompt,
            context: assistContext,
            sdkStatus: sdkStatus,
            projectName: activeProject?.name,
            requireProjectTools: requireProjectTools,
            additionalSystemPrompt: additionalSystemPrompt
        )

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
        /// Tools actually executed this run — the Project mandate's
        /// counter (`AgentToolPolicy`).
        var toolCallsExecuted = 0
        /// Times the loop has already sent the model back to use a tool.
        var projectToolRejections = 0
        /// Reasoning split out of the model's turns, in order. Surfaced
        /// as thought steps and on the outcome — never inside the answer.
        var accumulatedThinking: [String] = []
        /// Canonical signatures of tool calls already executed this run —
        /// the no-progress guard (`AntigravityLoopEngine.isNoProgressRepeat`).
        var executedSignatures: [String] = []
        /// Requests the validator refused (unregistered ids, malformed
        /// payloads, schema-invalid arguments). Each is fed back as a
        /// correction; the run stops when they stop being corrective.
        var rejectedToolCalls = 0
        /// Turn announcements that described work without requesting it.
        var narrationTurns = 0
        var narrationSignatures: [String] = []
        /// The last refusal, so a stopped run can say what went wrong.
        var lastRejection: ToolCallRejection?
        /// Consecutive empty model turns; bounded, then the run stops
        /// honestly instead of spinning to the turn cap.
        var emptyTurns = 0
        /// Set when the loop stops for a guard/limit reason; the post-loop
        /// path reports it as an incomplete run, never as a success with
        /// the last raw thought pasted in as the "answer".
        var loopStoppedReason: String?

        // 3. Multi-turn Agent Loop
        loop: while turnCount < turnBudget && !Task.isCancelled {
            turnCount += 1
            dispatchStatus(.thinking)
            currentThought = ""

            let fullPrompt = Self.assemblePrompt(turns: conversationTurns)

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
                // A cancelled run is a cancellation, not a model error: report
                // it as such so the UI never blames inference for the user's
                // stop.
                if Task.isCancelled {
                    dispatchStatus(.idle)
                    return AgentExecutionOutcome(answer: "Execution was cancelled.", steps: steps, success: false)
                }
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

            // This turn's reasoning, split out before classification: it
            // belongs in a thought step (and the outcome's thinking), not
            // in any answer text, whichever way the turn classifies.
            let turnThinking = AntigravityLoopEngine.splitThinking(from: turnResponse).thinking
            if let turnThinking, !turnThinking.isEmpty {
                accumulatedThinking.append(turnThinking)
                addStep(AgentStep(kind: .thought, title: "Thinking", detail: turnThinking))
            }

            // 4. Classify the turn with the loop engine. Tool turns are
            // consumed entirely by the loop: their text (which contains the
            // raw invocation) is never forwarded to the chat as a message.
            switch AntigravityLoopEngine.decide(turnText: turnResponse, catalog: catalog) {
            case .callTool(let toolId, let codableArgs):
                // Execution budget: a run may not spin through tools forever.
                guard toolCallsExecuted < executionBudget else {
                    loopStoppedReason = "I stopped this run at the tool limit (\(executionBudget) actions). The steps from this run show what was executed; anything after the limit did not run."
                    break loop
                }

                // No-progress guard: the same tool with the same
                // arguments cannot produce new information a third time.
                // Stop and say so instead of burning the turn budget.
                let validated = ValidatedToolCall(toolID: toolId, toolName: ToolNameFormatter.format(toolId), arguments: codableArgs)
                if AntigravityLoopEngine.isNoProgressRepeat(signature: validated.signature, previousSignatures: executedSignatures) {
                    addStep(AgentStep(
                        kind: .thought,
                        title: "Repeated Action Stopped",
                        detail: "The model requested the same action with the same inputs again after \(AntigravityLoopEngine.maxIdenticalToolExecutions) identical executions. Repeating it cannot make progress, so the run stopped."
                    ))
                    loopStoppedReason = "I stopped this run because the same step was repeated with identical inputs and could not make further progress. \(toolCallsExecuted) tool step(s) ran before that — the steps from this run show what was done."
                    break loop
                }
                guard let tool = ToolsRegistry.shared.tool(for: toolId) else {
                    // The catalog and the registry are built from the same
                    // source; a miss here means the registry changed mid-run.
                    rejectedToolCalls += 1
                    conversationTurns.append(Turn(role: "user", content: AntigravityLoopEngine.correctionPrompt(rejection: .unknownTool(toolId))))
                    if rejectedToolCalls >= AntigravityLoopEngine.maxRejectedToolCalls {
                        loopStoppedReason = "I stopped this run because the action it requested is no longer available. Nothing further was executed."
                        break loop
                    }
                    continue
                }
                executedSignatures.append(validated.signature)
                toolCallsExecuted += 1
                narrationTurns = 0

                let args = codableArgs
                let preview = sanitizedArgumentPreview(args)
                var record = ToolCallRecord(
                    toolID: toolId,
                    arguments: preview,
                    status: .running,
                    startedAt: .now
                )
                toolCallRecords.append(record)
                onEvent?(.toolCallRecordUpdated(record))

                self.activeToolName = toolId
                dispatchStatus(.callingTool(name: toolId))
                onEvent?(.toolCallDetected(tool: toolId, arguments: args.mapValues(\.anyValue)))
                onEvent?(.toolExecutionStarted(tool: toolId))

                let callStep = AgentStep(
                    kind: .toolCall,
                    title: ToolNameFormatter.format(toolId),
                    detail: formatArgumentsPreview(args.mapValues(\.anyValue)),
                    rawPayload: turnResponse,
                    toolName: toolId,
                    toolArguments: args.mapValues(\.anyValue),
                    callID: record.id.uuidString
                )
                addStep(callStep)

                // Execute the real implementation, bounded by the run's
                // per-call timeout. A throw or a timeout is a failure result,
                // never a fabricated success.
                let execution = await ToolExecutor.execute(
                    tool: tool,
                    arguments: args,
                    context: assistContext,
                    timeout: toolTimeout
                )
                let result = execution.result

                record.status = result.success ? .completed : .failed(result.error ?? "Execution failed")
                record.result = result.output
                record.duration = execution.duration
                record.completedAt = .now
                if let index = toolCallRecords.firstIndex(where: { $0.id == record.id }) {
                    toolCallRecords[index] = record
                }
                onEvent?(.toolCallRecordUpdated(record))

                dispatchStatus(.toolCompleted(name: toolId))
                onEvent?(.toolExecutionFinished(tool: toolId, result: result))

                if !result.success {
                    // A failed call is not a completed step. The model is told
                    // exactly that, so it cannot report the action as done.
                    addStep(AgentStep(
                        kind: .error,
                        title: "\(ToolNameFormatter.format(toolId)) Failed",
                        detail: result.error ?? result.output,
                        toolName: toolId,
                        toolResult: result,
                        callID: record.id.uuidString
                    ))
                } else {
                    addStep(AgentStep(
                        kind: .toolResult,
                        title: ToolNameFormatter.completedTitle(for: toolId),
                        detail: result.output,
                        toolName: toolId,
                        toolResult: result,
                        callID: record.id.uuidString
                    ))
                }

                // Feed tool result back into conversation turns. The
                // assistant turn is recorded as a neutral marker, not the
                // raw invocation text, so the model's own history stops
                // teaching it to paste invocations into prose.
                // A plain sentence, not a bracketed marker: bracketed
                // loop-control strings in the history taught models to
                // emit "[Answer withheld]"-style artifacts as prose.
                conversationTurns.append(Turn(role: "assistant", content: "I completed a step using a tool."))
                conversationTurns.append(Turn(
                    role: "user",
                    content: AntigravityLoopEngine.observationPrompt(toolID: toolId, output: result.output, success: result.success)
                ))

                self.activeToolName = nil

            case .invalidToolCall(_, let rejection):
                // Nothing was executed. The turn's text (the model's own
                // description of what it meant to do) is never forwarded as a
                // message, and no result is invented. The loop feeds back a
                // correction naming the defect; a model that keeps requesting
                // unusable actions is stopped instead of looped.
                rejectedToolCalls += 1
                lastRejection = rejection
                addStep(AgentStep(
                    kind: .error,
                    title: "Action Not Executed",
                    detail: rejection.userFacingSummary
                ))
                conversationTurns.append(Turn(role: "assistant", content: "That action did not run."))
                conversationTurns.append(Turn(
                    role: "user",
                    content: AntigravityLoopEngine.correctionPrompt(rejection: rejection)
                ))
                if rejectedToolCalls >= AntigravityLoopEngine.maxRejectedToolCalls {
                    let reason = lastRejection?.userFacingSummary ?? "The request could not be executed."
                    loopStoppedReason = "I stopped this run because the model kept requesting actions this app cannot execute. \(reason) \(toolCallsExecuted) tool step(s) ran before that — nothing else was executed."
                    break loop
                }
                continue

            case .finalAnswer(let answer):
                // The answer text with its reasoning removed — the
                // reasoning was already captured as a thought step above,
                // and it must not ride along inside the answer.
                let cleanAnswer = AntigravityLoopEngine.splitThinking(from: answer).answer

                // Empty / malformed turn: one nudge, then stop honestly.
                // An empty turn is not an answer, and spinning to the
                // turn cap used to end with the raw last thought pasted
                // in as a fake final answer.
                if cleanAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    emptyTurns += 1
                    if emptyTurns < 2 {
                        conversationTurns.append(Turn(
                            role: "user",
                            content: "Your last reply was empty. Continue: either call a tool for the next step, or give the final answer now."
                        ))
                        continue
                    }
                    loopStoppedReason = "I stopped this run because the model returned empty responses instead of an answer or a tool call. \(toolCallsExecuted) tool step(s) ran before that."
                    break loop
                }
                emptyTurns = 0

                // Narration is not execution. A turn that announces work
                // ("I will run it now") without requesting it through the
                // tool channel is not a result: the model is corrected once,
                // and a second announcement stops the run with a status that
                // says plainly nothing ran. This is what used to let a model
                // print a command in a code block and call it done.
                if AntigravityLoopEngine.describesPendingAction(cleanAnswer) {
                    narrationTurns += 1
                    let narrationSignature = AntigravityLoopEngine.narrationSignature(cleanAnswer)
                    let repeatedNarration = narrationSignatures.filter { $0 == narrationSignature }.count
                    narrationSignatures.append(narrationSignature)
                    addStep(AgentStep(
                        kind: .thought,
                        title: "Action Described, Not Taken",
                        detail: "The model described an action instead of requesting it. Only a real tool call executes, so nothing was run for that turn."
                    ))
                    if narrationTurns >= AntigravityLoopEngine.maxNarrationTurns || repeatedNarration >= 1 {
                        loopStoppedReason = "I stopped this run because the model kept describing actions instead of performing them: nothing it described was executed. Only real tool calls run in this app, and \(toolCallsExecuted) tool step(s) did run before the repetition."
                        break loop
                    }
                    conversationTurns.append(Turn(role: "assistant", content: "I described an action without taking it."))
                    conversationTurns.append(Turn(role: "user", content: AntigravityLoopEngine.narrationCorrectionPrompt))
                    continue
                }

                // Project Tool Mandate: with a project active, a final
                // answer is only acceptable after the agent has actually
                // used its tools in the project. A tool-less answer is
                // rejected and the model is sent back to explore first.
                // TASK turns only (`intent` in AgentToolPolicy) — and no
                // assistant-turn marker is written for the rejected
                // draft any more: the old "[Draft answer withheld …]"
                // history entry is the direct origin of the
                // "[Answer withheld]" artifact users saw in the UI,
                // because models echoed the marker back as prose.
                if AgentToolPolicy.mustRejectFinalAnswer(
                    toolCallsExecuted: toolCallsExecuted,
                    projectActive: activeProject != nil,
                    requireToolUse: requireProjectTools,
                    rejectionsUsed: projectToolRejections,
                    intent: intent
                ), let project = activeProject {
                    projectToolRejections += 1
                    addStep(AgentStep(
                        kind: .thought,
                        title: "Project Tool Mandate",
                        detail: "The model tried to answer about \"\(project.name)\" without using any tools. The answer was rejected — in a project, work must be grounded in tool results from this run."
                    ))
                    conversationTurns.append(Turn(
                        role: "user",
                        content: AgentToolPolicy.rejectionPrompt(projectName: project.name)
                    ))
                    continue
                }

                finalAnswer = cleanAnswer
                let finalStep = AgentStep(
                    kind: .finalAnswer,
                    title: "Final Answer",
                    detail: finalAnswer
                )
                addStep(finalStep)
                dispatchStatus(.finished)
                onEvent?(.completed(answer: finalAnswer, steps: steps))
                return AgentExecutionOutcome(
                    answer: finalAnswer,
                    steps: steps,
                    success: true,
                    thinking: accumulatedThinking.isEmpty ? nil : accumulatedThinking.joined(separator: "\n\n")
                )
            }
        }

        // The loop ended without a final answer: a guard stopped it, or
        // the turn cap was reached. Report the actual status — the old
        // code pasted the model's last raw thought in as a successful
        // "answer", which is how partial internal transcripts (thinking,
        // instruction echoes, loop markers) reached the chat as prose.
        let runSucceeded = loopStoppedReason == nil && !finalAnswer.isEmpty
        if finalAnswer.isEmpty {
            finalAnswer = Task.isCancelled
                ? "Execution was cancelled."
                : (loopStoppedReason
                    ?? "I reached the step limit (\(turnBudget) turns) before finishing this task. \(toolCallsExecuted) tool step(s) ran — the steps from this run show what was done, and nothing further was executed.")
            addStep(AgentStep(kind: .finalAnswer, title: "Run Stopped", detail: finalAnswer))
        }

        dispatchStatus(.finished)
        onEvent?(.completed(answer: finalAnswer, steps: steps))
        return AgentExecutionOutcome(
            answer: finalAnswer,
            steps: steps,
            success: runSucceeded,
            error: runSucceeded ? nil : finalAnswer,
            thinking: accumulatedThinking.isEmpty ? nil : accumulatedThinking.joined(separator: "\n\n")
        )
    }

    // MARK: - Prompt Construction

    private func buildSystemPrompt(
        query: String,
        context: AssistContext,
        sdkStatus: AntigravitySDKBundle.Status,
        projectName: String?,
        requireProjectTools: Bool,
        additionalSystemPrompt: String? = nil
    ) -> String {
        // Index-based context: the counts-only directory, plus the tool
        // schemas the local retriever selected for this run's prompt
        // (core tools first, inside the tool sub-budget). Everything else
        // — the remaining tools' schemas, asset bodies, skills, memory —
        // stays in the index and is retrieved on demand during the run.
        let directory = ContextIndexManager.directoryText(mode: .agent)
        let toolsSchema = ContextIndexManager.agentToolSchemaBundle(
            query: query,
            hasActiveProject: context.agentProjectID != nil
        )

        // Computer Use state, stated plainly so the model uses the suite
        // when it is on and explains (instead of attempting) when it is
        // off. Computer tools' schemas join `toolsSchema` whenever the
        // retriever selects them for the task — this line is what
        // connects them to the SDK loop the model is running in.
        let computerUseLine = ComputerUseSettings.isEnabled
            ? "Computer Use is ON: this Mac's screen and apps are available to you through the desktop tools in your tool list (screenshots, screen text, accessibility, mouse, keyboard, windows). Work observe → act → verify: look at the screen first, do one action, then verify the result before continuing."
            : "Computer Use is OFF (Settings → Computer Use). The desktop tools will decline to act; if a task needs the screen or another app, tell the user it needs Computer Use turned on instead of attempting it."

        var prompt = """
        # Antigravity Agent Runtime

        You are an autonomous AI agent running locally and privately on macOS via Locally.
        Your goal is to solve the user's objective thoroughly, safely, and concisely using the tools provided.

        \(AntigravitySDKBundle.agentModeContextLine(status: sdkStatus))
        \(computerUseLine)

        ## Core Operational Guidelines:
        1. When a task requires external data, system verification, or computation, use the available tools.
        2. To call a tool, output ONLY a single line in this exact JSON format:
           TOOL_CALL {"tool": "<tool_id>", "arguments": { ... }}
           ids that are not registered are rejected and nothing runs — retrieve a tool's schema from the context index first if you are unsure.
        3. Do not include extra conversational text on the line of a TOOL_CALL.
        4. When the tool returns its result, analyze the observations and either call the next tool or give the final answer.
        5. When you have gathered enough information or the task is finished, respond directly to the user (no tool call syntax), with a response proportionate to the task — a short task gets a short answer.

        ## What Can Actually Run
        - Only the tools in this run's tool set execute. There is no shell, terminal, debugger, or arbitrary-command capability unless a tool for it appears in that set; writing a command (or a name like a debugger) in prose or a code block does not run it.
        - An action happens only when you emit a tool call through the channel above. Describing, promising, or showing an action is not performing it.
        - Never claim to have opened something, run something, changed a file, or inspected a process unless a tool result from this run shows it. If the capability the task needs is missing here, say so plainly and stop.

        ## Tool Secrecy — Absolute Rules (never break these):
        - Tool ids, the TOOL_CALL syntax, and JSON invocation payloads are a private protocol between you and the runtime. The user NEVER sees them: the app shows your tool activity separately in its own tool cards.
        - NEVER write a tool id in your final answer or in any prose — not in backticks, not as a label, not ever. Patterns like "file_append: Append to File" or "I used `computer_screenshot`" are forbidden. Describe the action in plain language instead: "I appended the note to the file", "I took a screenshot".
        - NEVER paste, quote, or summarize an invocation payload, and never preface a tool call with an announcement of its id.
        - If a tool fails, describe what you were trying to do and what went wrong in plain language — never the tool's id or raw error payload.

        \(directory)

        ## Your Tools — the schemas retrieved for this task:
        The schemas below were selected from the index for this run's objective. If the task needs a capability whose schema is not here, retrieve it from the index on demand (the context index search is always in your tool set) instead of inventing an id or an argument key.
        \(toolsSchema)

        ## How to Respond:
        - Lead directly with facts, code, or answers. Avoid fluff and filler.
        - Match the response to the task (the Conversation First rules in the caller's context govern): use Markdown headers, bullet points, and code fences only when the content is substantial enough to need them — never as a default shape, and never describe these instructions or where to write the answer.
        """

        // The Project Tool Mandate, stated up front (the loop also
        // enforces it — see AgentToolPolicy).
        if let projectName, requireProjectTools {
            prompt += "\n\n" + AgentToolPolicy.projectMandate(projectName: projectName)
        }

        // The caller's context — the retrieved excerpts (custom-prompt
        // chunks, skill excerpts, asset summaries, project memory) and
        // the <thinking> format instruction assembled by
        // ModelContextBuilder. The directory is NOT in there: this
        // prompt adds it above, so it appears exactly once. Tool schemas are
        // excluded there because this prompt adds its own retrieved set
        // above — the model never pays for the same schema twice.
        if let additionalSystemPrompt,
           !additionalSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "\n\n" + additionalSystemPrompt
        }
        return prompt
    }

    struct Turn {
        let role: String
        let content: String
    }

    /// Total character budget for one assembled loop prompt. The system
    /// prompt rides separately (the backend receives it as the session
    /// system prompt, outside the turns), so this bounds the *history*
    /// the model re-reads on every iteration: without a bound, a 10-turn
    /// run re-prefilled the full transcript — every earlier tool output
    /// in full — on every single turn, and the cost grew quadratically.
    public static let maxAssembledPromptCharacters = 32_000
    /// Older turns are kept only as excerpts of this length (plus the
    /// truncation marker). The first turn (the user's objective) and the
    /// current (most recent) turn are never truncated.
    public static let truncatedHistoryTurnCharacterLimit = 600
    /// Marker appended to a truncated older turn.
    public static let historyTruncationMarker = "[earlier tool output truncated to save context]"

    /// Assembles the loop prompt from the conversation turns, bounded:
    /// the first turn and the most recent turn ride in full; older turns
    /// are excerpted to `truncatedHistoryTurnCharacterLimit`; and if the
    /// result still exceeds `maxAssembledPromptCharacters`, the oldest
    /// middle turns are dropped (first + last two always survive) until
    /// it fits. Loop semantics are unchanged — only the history's size
    /// is bounded.
    static func assemblePrompt(turns: [Turn]) -> String {
        guard !turns.isEmpty else { return "Assistant:" }

        func render(_ turns: [(role: String, content: String)]) -> String {
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

        var bounded: [(role: String, content: String)] = turns.enumerated().map { index, turn in
            let isFirst = index == 0
            let isCurrent = index == turns.count - 1
            guard !isFirst, !isCurrent, turn.content.count > truncatedHistoryTurnCharacterLimit else {
                return (role: turn.role, content: turn.content)
            }
            return (
                role: turn.role,
                content: String(turn.content.prefix(truncatedHistoryTurnCharacterLimit)) + "\n" + historyTruncationMarker
            )
        }

        var assembled = render(bounded)
        while assembled.count > maxAssembledPromptCharacters, bounded.count > 3 {
            bounded.remove(at: 1)
            assembled = render(bounded)
        }
        return assembled
    }

    /// Arguments as they appear in the run record and the call card: string
    /// values verbatim (bounded), everything else rendered plainly. The model's
    /// raw payload is never shown as message text.
    private func sanitizedArgumentPreview(_ args: [String: AnyCodableValue]) -> [String: String] {
        let limit = 200
        return args.mapValues { value in
            let text: String = {
                if case .string(let string) = value { return string }
                return String(describing: value.anyValue)
            }()
            return text.count > limit ? String(text.prefix(limit)) + "…" : text
        }
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

    /// Extracts a tool request from the runtime's tool-call channel only.
    ///
    /// The channel is the `TOOL_CALL` marker (optionally followed by one JSON
    /// object) and the `<tool_call>` / `<function_call>` wrappers — the formats
    /// chat templates and the system prompt actually use for calling tools.
    ///
    /// Plain prose is never scanned for JSON: a command in a fenced block, a
    /// config example, or a sentence naming a tool is *content*, and treating
    /// it as an invocation is how a model's description of work used to become
    /// an executed call. Extraction here is purely syntactic — identity and
    /// arguments are validated afterwards by `ToolCallValidator`.
    public nonisolated static func parseToolCall(in text: String) -> (toolId: String, arguments: [String: Any])? {
        if let marker = text.range(of: "TOOL_CALL", options: .caseInsensitive) {
            let remainder = text[marker.upperBound...]
            if let start = remainder.firstIndex(of: "{"),
               let data = balancedJSON(in: remainder[start...]),
               let parsed = decodeToolCallData(data) {
                return parsed
            }
        }

        // XML-style wrapper a chat template may emit around the call.
        for tag in ["tool_call", "function_call", "tool_calls", "function_calls"] {
            guard let open = text.range(of: "<\(tag)", options: .caseInsensitive) else { continue }
            let body = text[open.upperBound...]
            if let start = body.firstIndex(of: "{"),
               let data = balancedJSON(in: body[start...]),
               let parsed = decodeToolCallData(data) {
                return parsed
            }
        }

        return nil
    }

    /// True when the text contains the tool-call channel but its payload could
    /// not be read. Such a turn is an invalid call (refused, corrected), never
    /// an answer: printing it would leak protocol text and executing it would
    /// be guesswork.
    public nonisolated static func containsToolCallChannel(_ text: String) -> Bool {
        if text.range(of: "TOOL_CALL", options: .caseInsensitive) != nil { return true }
        for tag in ["tool_call", "function_call"] where text.range(of: "<\(tag)", options: .caseInsensitive) != nil {
            return true
        }
        return false
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
