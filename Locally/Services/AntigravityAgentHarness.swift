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

    /// The identity of the run currently executing, if any. Every stream
    /// event, tool dispatch, and outcome of a run is tied to this id;
    /// consumers (ChatViewModel) apply an event only while its run is
    /// still the active one, so a late result from a superseded run
    /// cannot overwrite a newer answer.
    public private(set) var activeRunID: UUID?
    /// Runs explicitly cancelled by id. A run checks this set (in
    /// addition to its task's cancellation) before every model request
    /// and every tool dispatch: cancelling run A records A's id, so a
    /// newer run B — different id, same singleton harness — is never
    /// cancelled or corrupted by A's stop.
    private var cancelledRunIDs: Set<UUID> = []

    private var activeTask: Task<Void, Never>?

    public init() {}

    /// True when the given run must stop: its task was cancelled, or it
    /// was cancelled by id via `cancel(runID:)`.
    public func isRunCancelled(_ runID: UUID) -> Bool {
        Task.isCancelled || cancelledRunIDs.contains(runID)
    }

    /// Cancels any in-flight agent execution.
    public func cancel() {
        if let activeRunID {
            cancelledRunIDs.insert(activeRunID)
        }
        activeTask?.cancel()
        activeTask = nil
        if isRunning {
            status = .idle
            isRunning = false
            activeToolName = nil
        }
    }

    /// Cancels one specific run by id. If that run is not the active one
    /// this does NOT touch the active run's state — it only records the
    /// id, so the targeted run (wherever it is observed) stops and its
    /// late events are dropped by run-id checks.
    public func cancel(runID: UUID) {
        cancelledRunIDs.insert(runID)
        if runID == activeRunID {
            cancel()
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
        conversationHistory: [Turn]? = nil,
        modelID: String? = nil,
        workspaceRoot: URL = URL.documentsDirectory,
        projectID: UUID? = nil,
        maxTurns: Int = 10,
        maxToolExecutions: Int = AntigravityLoopEngine.maxToolExecutionsPerRun,
        toolTimeout: Duration = ToolExecutor.defaultTimeout,
        runID: UUID? = nil,
        runDuration: Duration = GenerationDefaults.maxAgentRunDuration,
        turnDuration: Duration = GenerationDefaults.maxAgentTurnDuration,
        backend: (any InferenceBackend)? = nil,
        additionalSystemPrompt: String? = nil,
        onEvent: (@MainActor (AgentHarnessEvent) -> Void)? = nil
    ) async -> AgentExecutionOutcome {
        cancel()
        // This run's identity. Callers that need to correlate events,
        // cancellation, and the outcome with their own state pass their
        // id in; otherwise the run mints one. From here on, every
        // cancellation check and every deadline is scoped to THIS run.
        let thisRunID = runID ?? UUID()
        activeRunID = thisRunID
        let runScope = GenerationRun(id: thisRunID, startedAt: .now)
        isRunning = true
        steps = []
        toolCallRecords = []
        currentThought = ""
        status = .thinking
        activeToolName = nil
        let turnBudget = max(1, min(maxTurns, 32))
        let executionBudget = max(1, maxToolExecutions)

        /// The per-turn stream deadline: the turn's own limit, or
        /// whatever is left of the run's limit, whichever ends first.
        func turnDeadline() -> Duration {
            min(turnDuration, runScope.remaining(limit: runDuration))
        }
        /// True when this run's wall-clock limit has expired.
        func runExpired() -> Bool {
            runScope.hasExceeded(limit: runDuration)
        }
        /// The timeout explanation a run ends with when its limit hits.
        func runTimeoutReason() -> String {
            "I stopped this run at its time limit (\(Int(GenerationRun.seconds(from: runDuration).rounded()))s). The steps from this run show what was completed before the limit; nothing after it ran."
        }

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
            // Only the run that still owns the harness may clear its
            // state — a finishing old run must not mark a newer run as
            // not-running, erase its identity (which would silently
            // un-scope its events), or forget its cancellation record
            // before it has observed it.
            if self.activeRunID == thisRunID {
                self.isRunning = false
                self.activeToolName = nil
                self.activeRunID = nil
                self.cancelledRunIDs.remove(thisRunID)
            }
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
                conversationHistory: conversationHistory,
                workspaceRoot: workspaceRoot,
                projectID: projectID,
                maxTurns: maxTurns,
                runID: thisRunID,
                maxDuration: runDuration,
                maxToolExecutions: executionBudget,
                toolTimeout: toolTimeout,
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
            return ModelContextBuilder.build(ModelContextBuilder.Input(isAgentMode: true, capability: ModelCapabilityProfile.profile(forModelID: targetModelID), intent: intent))
        }()

        /// One direct generation. Returns the cleaned answer, its
        /// split-out thinking, and whether the model tried to call a
        /// tool instead of answering.
        func directTurn(extraInstruction: String? = nil) async -> (answer: String, thinking: String?, wantsTool: Bool) {
            var text = ""
            do {
                let rawStream = try selectedBackend.stream(
                    prompt: prompt,
                    systemPrompt: extraInstruction.map { directSystemPrompt + "\n\n" + $0 } ?? directSystemPrompt
                )
                // A direct turn is a generation like any other: it gets
                // the turn deadline, so a conversational reply cannot
                // hang or dribble past the limit either.
                let stream = StreamTimeout.events(rawStream, after: turnDeadline())
                for try await event in stream {
                    if isRunCancelled(thisRunID) { break }
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
            if AntigravityLoopEngine.describesPendingAction(split.answer) {
                return ("", split.thinking, true)
            }
            let cleaned = AntigravityLoopEngine.cleanFinalAnswer(split.answer, knownToolIDs: knownToolIDs)
            if AntigravityLoopEngine.describesPendingAction(cleaned) {
                return ("", split.thinking, true)
            }
            return (cleaned, split.thinking, false)
        }

        if intent != .task {
            var direct = await directTurn()
            if intent == .conversational && (direct.wantsTool || direct.answer.isEmpty) && !isRunCancelled(thisRunID) && !runExpired() {
                // One retry with the plain-text requirement stated again.
                // Never a hardcoded reply: if the model still cannot
                // answer conversationally, the failure is reported as one.
                direct = await directTurn(extraInstruction: "[This Turn — retry]: Answer in plain conversational text only. Do not call, mention, or describe any tool, skill, or instruction.")
            }

            if direct.wantsTool {
                // Escalation: the model requested a tool or described pending action / unexecuted capability —
                // fall through to the full agent tool loop below so that the tool is actually executed!
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

        // Model compatibility, stated before the task loop starts: a
        // constrained model on the text tool-call protocol (e.g. a
        // 0.5B instruct model) gets a visible warning in the run trace
        // instead of silently attempting autonomous execution it cannot
        // reliably perform. The loop's guards still apply unchanged;
        // this is disclosure, not a block — and Chat mode never sees it.
        if let advisory = ModelCapabilityProfile.profile(forModelID: targetModelID).agentModeAdvisory {
            addStep(AgentStep(kind: .thought, title: "Model Capability Warning", detail: advisory))
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
            workspaceRoot: workspaceRoot,
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

        var conversationTurns: [Turn]
        if let conversationHistory, !conversationHistory.isEmpty {
            conversationTurns = conversationHistory
            if conversationTurns.last?.role != "user" || conversationTurns.last?.content != prompt {
                conversationTurns.append(Turn(role: "user", content: prompt))
            }
        } else {
            conversationTurns = [
                Turn(role: "user", content: prompt)
            ]
        }

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
        /// Signatures of every non-empty assistant text turn this run
        /// produced (see `AntigravityLoopEngine.textTurnSignature`). A
        /// text turn the loop continues past — a rejected draft, a
        /// tool-state sentence — that repeats verbatim is no progress,
        /// even though no tool call is involved for the tool guard to see.
        var textTurnSignatures: [String] = []
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
        loop: while turnCount < turnBudget && !isRunCancelled(thisRunID) {
            turnCount += 1

            // Run deadline, checked before every model request: a run
            // that has used its time budget schedules nothing further —
            // no more generations, no more tools — and ends below with
            // the timeout as its terminal state.
            if runExpired() {
                loopStoppedReason = runTimeoutReason()
                break loop
            }
            dispatchStatus(.thinking)
            currentThought = ""

            let fullPrompt = Self.assemblePrompt(turns: conversationTurns)

            var turnResponse = ""
            var turnTimedOut = false
            do {
                let rawStream = try selectedBackend.stream(prompt: fullPrompt, systemPrompt: systemPrompt)
                let stream = StreamTimeout.events(rawStream, after: turnDeadline())
                for try await event in stream {
                    if isRunCancelled(thisRunID) { break }
                    switch event {
                    case .token(let token):
                        turnResponse += token
                        self.currentThought = turnResponse
                        onEvent?(.tokenStreamed(token))
                    case .finished:
                        break
                    }
                }
            } catch let error as GenerationTimeoutError {
                // One turn exceeded its deadline (or the run's remaining
                // time): terminal for the run, with the work already done
                // preserved in the steps — not a model error, and never a
                // silent continuation into another turn.
                _ = error
                turnTimedOut = true
            } catch {
                // A cancelled run is a cancellation, not a model error: report
                // it as such so the UI never blames inference for the user's
                // stop.
                if isRunCancelled(thisRunID) {
                    dispatchStatus(.idle)
                    return AgentExecutionOutcome(answer: "Execution was cancelled.", steps: steps, success: false)
                }
                let msg = "Inference generation error: \(error.localizedDescription)"
                dispatchStatus(.failed(msg))
                let errStep = AgentStep(kind: .error, title: "Inference Error", detail: msg)
                addStep(errStep)
                return AgentExecutionOutcome(answer: finalAnswer, steps: steps, success: false, error: msg)
            }

            if turnTimedOut {
                loopStoppedReason = runExpired() ? runTimeoutReason()
                    : "I stopped this run because one model turn exceeded its time limit (\(Int(GenerationRun.seconds(from: turnDuration).rounded()))s) without finishing. \(toolCallsExecuted) tool step(s) ran before that — the steps from this run show what was done."
                break loop
            }

            if isRunCancelled(thisRunID) {
                dispatchStatus(.idle)
                return AgentExecutionOutcome(answer: "Execution was cancelled.", steps: steps, success: false)
            }

            // This turn's reasoning, split out before classification: it
            // belongs in a thought step (and the outcome's thinking), not
            // in any answer text, whichever way the turn classifies.
            let turnSplit = AntigravityLoopEngine.splitThinking(from: turnResponse)
            let turnThinking = turnSplit.thinking
            if let turnThinking, !turnThinking.isEmpty {
                accumulatedThinking.append(turnThinking)
                addStep(AgentStep(kind: .thought, title: "Thinking", detail: turnThinking))
            }

            // 4. Classify the turn with the loop engine. Tool turns are
            // consumed entirely by the loop: their text (which contains the
            // raw invocation) is never forwarded to the chat as a message.
            // Classification runs on the ANSWER portion only — never on
            // the raw turn. The raw turn includes the model's reasoning,
            // and a call merely *considered* inside <thinking> ("maybe I
            // should TOOL_CALL …") is not a call the model made: deciding
            // on the raw text could execute an action the model only
            // thought about. (The direct-turn path already decided on
            // the split answer; the loop now matches it.)
            func executeSingleTool(toolId: String, codableArgs: [String: AnyCodableValue]) async -> (success: Bool, output: String)? {
                let validated = ValidatedToolCall(toolID: toolId, toolName: ToolNameFormatter.format(toolId), arguments: codableArgs)
                if AntigravityLoopEngine.isNoProgressRepeat(signature: validated.signature, previousSignatures: executedSignatures) {
                    addStep(AgentStep(
                        kind: .thought,
                        title: "Repeated Action Stopped",
                        detail: "The model requested the same action with the same inputs again after \(AntigravityLoopEngine.maxIdenticalToolExecutions) identical executions. Repeating it cannot make progress, so the run stopped."
                    ))
                    loopStoppedReason = "I stopped this run because the same step was repeated with identical inputs and could not make further progress. \(toolCallsExecuted) tool step(s) ran before that — the steps from this run show what was done."
                    return nil
                }
                guard let tool = ToolsRegistry.shared.tool(for: toolId) else {
                    rejectedToolCalls += 1
                    conversationTurns.append(Turn(role: "user", content: AntigravityLoopEngine.correctionPrompt(rejection: .unknownTool(toolId))))
                    if rejectedToolCalls >= AntigravityLoopEngine.maxRejectedToolCalls {
                        loopStoppedReason = "I stopped this run because the action it requested is no longer available. Nothing further was executed."
                    }
                    return nil
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

                // Check for truncation metadata so the model understands bounds.
                var deliveryOutput = result.output
                if let data = result.data {
                    if data["truncated"] == "true" || data[AssistToolDataKey.truncated] == "true" {
                        if !deliveryOutput.contains("[Output truncated") && !deliveryOutput.contains("[NOTICE: Output was truncated") {
                            let total = data["totalLines"] ?? data[AssistToolDataKey.totalLines]
                            let totalNote = total != nil ? " (total lines: \(total!))" : ""
                            deliveryOutput += "\n\n[NOTICE: Output was truncated to fit bounds\(totalNote). Use line ranges or narrower filters to view specific sections.]"
                        }
                    } else if data["fullyAvailable"] == "false", let total = data["totalLines"], let start = data["start"], let end = data["end"] {
                        if !deliveryOutput.contains("lines \(start)-\(end) of \(total)") {
                            deliveryOutput += "\n\n[NOTICE: Partial file slice returned: lines \(start)-\(end) of \(total). Use lines {start, end} to read other ranges.]"
                        }
                    }
                }

                return (result.success, deliveryOutput)
            }

            switch AntigravityLoopEngine.decide(turnText: turnSplit.answer, catalog: catalog) {
            case .callTool(let toolId, let codableArgs):
                if isRunCancelled(thisRunID) {
                    dispatchStatus(.idle)
                    return AgentExecutionOutcome(answer: "Execution was cancelled.", steps: steps, success: false)
                }
                if runExpired() {
                    loopStoppedReason = runTimeoutReason()
                    break loop
                }
                guard toolCallsExecuted < executionBudget else {
                    loopStoppedReason = "I stopped this run at the tool limit (\(executionBudget) actions). The steps from this run show what was executed; anything after the limit did not run."
                    break loop
                }

                if let outcome = await executeSingleTool(toolId: toolId, codableArgs: codableArgs) {
                    conversationTurns.append(Turn(role: "assistant", content: "I completed a step using a tool."))
                    conversationTurns.append(Turn(
                        role: "user",
                        content: AntigravityLoopEngine.observationPrompt(toolID: toolId, output: outcome.output, success: outcome.success)
                    ))
                } else if loopStoppedReason != nil {
                    break loop
                }
                self.activeToolName = nil

            case .callTools(let calls):
                if isRunCancelled(thisRunID) {
                    dispatchStatus(.idle)
                    return AgentExecutionOutcome(answer: "Execution was cancelled.", steps: steps, success: false)
                }
                if runExpired() {
                    loopStoppedReason = runTimeoutReason()
                    break loop
                }
                guard toolCallsExecuted < executionBudget else {
                    loopStoppedReason = "I stopped this run at the tool limit (\(executionBudget) actions). The steps from this run show what was executed; anything after the limit did not run."
                    break loop
                }

                var multiObservations: [(toolID: String, output: String, success: Bool)] = []
                for call in calls {
                    if isRunCancelled(thisRunID) || runExpired() || toolCallsExecuted >= executionBudget {
                        break
                    }
                    if let outcome = await executeSingleTool(toolId: call.toolID, codableArgs: call.arguments) {
                        multiObservations.append((toolID: call.toolID, output: outcome.output, success: outcome.success))
                    } else if loopStoppedReason != nil {
                        break
                    }
                }
                if !multiObservations.isEmpty {
                    conversationTurns.append(Turn(role: "assistant", content: "I completed multiple steps using tools."))
                    conversationTurns.append(Turn(
                        role: "user",
                        content: AntigravityLoopEngine.multiObservationPrompt(results: multiObservations)
                    ))
                }
                if loopStoppedReason != nil {
                    break loop
                }
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

                // Repeated-text guard: this run already produced this
                // exact text turn once and the loop continued past it
                // (below, via a mandate rejection). Producing it again
                // is no progress by definition — the tool guard cannot
                // see it, because no tool call is involved. This is the
                // rejected draft (or a tool-state sentence like "that
                // tool was not called") repeated until the turn cap.
                // Narration turns are handled above with their own
                // guard and never reach here twice.
                let textSignature = AntigravityLoopEngine.textTurnSignature(cleanAnswer)
                if AntigravityLoopEngine.isRepeatedTextTurn(signature: textSignature, previousSignatures: textTurnSignatures) {
                    addStep(AgentStep(
                        kind: .thought,
                        title: "Repeated Response Stopped",
                        detail: "The model produced the same response again after the loop had already continued past it once. Repeating it cannot make progress, so the run stopped."
                    ))
                    loopStoppedReason = "I stopped this run because the model repeated the same response instead of progressing. \(toolCallsExecuted) tool step(s) ran before that — the steps from this run show what was done."
                    break loop
                }
                textTurnSignatures.append(textSignature)

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
            finalAnswer = isRunCancelled(thisRunID)
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
        workspaceRoot: URL,
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

        ## Workspace — where file actions happen:
        - This run's workspace folder is: \(workspaceRoot.path)
        - Relative paths in tool arguments resolve inside that folder. "This directory", "the current directory", and "here" in the user's request mean exactly that folder — nowhere else.
        - Terminal Execution: When shell commands are needed (`git`, `swift`, builds, `grep`, `find`, project tasks), invoke `use_terminal` via a TOOL_CALL with the specific command. Never write shell commands in prose expecting them to run automatically.
        - To create a file named with a plain filename (for example `main.swift`) in "this directory", call the file-creation tool `file_create` with that filename as its `path` argument and the file's full content. Do not invent a different folder.
        - When you create or change files, say in your final answer which folder they are in, in plain language.

        ## Real-File & Real-Result Integrity Mandate:
        - NEVER create mock files, placeholder files, or dummy implementations because a requested file was not found. If an item does not exist, report that reality truthfully.
        - NEVER invent file contents, terminal output, build logs, or test results. Everything you report must be grounded in real observations from executed tools.
        - Read-only requests ("Read this file", "Inspect this view", "Explain how this project works", "Find the implementation") must remain strictly read-only. NEVER create, modify, rename, or delete files on a read-only request.
        - Missing-file protocol: If a target file is not found initially, verify the workspace root, broaden searches with `file_search`, inspect directories with `dir_read` or `tree_view`, and use `project_inspect`. Report actual search results honestly.
        - Inspect before editing: Always read an existing file before modifying it, make the smallest coherent changes, and verify changes on disk.

        ## Core Operational Guidelines:
        1. When a task requires external data, system verification, or computation, use the available tools.
        2. To call a tool, output ONLY a single line in this exact JSON format:
           TOOL_CALL {"tool": "<tool_id>", "arguments": { ... }}
           ids that are not registered are rejected and nothing runs — retrieve a tool's schema from the context index first if you are unsure.
        3. Do not include extra conversational text on the line of a TOOL_CALL.
        4. When the tool returns its result, analyze the observations and either call the next tool or give the final answer.
        5. When you have gathered enough information or the task is finished, respond directly to the user (no tool call syntax), with a response proportionate to the task — a short task gets a short answer.

        ## What Can Actually Run
        - Only the tools in this run's tool set execute. Terminal commands execute only when `use_terminal` is invoked via TOOL_CALL; writing a command in prose or a code block does not run it.
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

    public struct Turn: Sendable, Equatable {
        public let role: String
        public let content: String

        public init(role: String, content: String) {
            self.role = role
            self.content = content
        }
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

    /// Extracts all tool requests from the turn text. Supports:
    /// - `TOOL_CALL: {...}` (with optional colon)
    /// - `TOOL_CALL\n{...}` (newline before payload)
    /// - Standalone line `TOOL_CALL {"tool": ...}`
    /// - Fenced code blocks containing `TOOL_CALL` or `{"tool": ...}`
    /// - `<tool_call>...` and `<tool_calls>...` wrappers
    /// - `<function=tool_name>...` and `<function name="tool_name">...` tags
    public nonisolated static func parseToolCalls(in text: String) -> [(toolId: String, arguments: [String: Any])] {
        let lowered = text.lowercased()
        let isDocExample = lowered.contains("here is an example") || lowered.contains("here is the payload shape")

        var results: [(toolId: String, arguments: [String: Any])] = []

        // 1. XML-style wrappers: <tool_call>, <function_call>, <tool_calls>, <function_calls>
        for tag in ["tool_call", "function_call", "tool_calls", "function_calls"] {
            var searchStart = text.startIndex
            while let open = text.range(of: "<\(tag)", options: .caseInsensitive, range: searchStart..<text.endIndex) {
                let close = text.range(of: "</\(tag)>", options: .caseInsensitive, range: open.upperBound..<text.endIndex)
                let tagSlice = close != nil ? text[open.upperBound..<close!.lowerBound] : text[open.upperBound...]

                var sliceRemaining = tagSlice
                while let data = balancedJSON(in: sliceRemaining),
                      let parsed = decodeToolCallData(data) {
                    if !results.contains(where: { $0.toolId == parsed.toolId && NSDictionary(dictionary: $0.arguments).isEqual(to: parsed.arguments) }) {
                        results.append(parsed)
                    }
                    if let str = String(data: data, encoding: .utf8),
                       let r = sliceRemaining.range(of: str) {
                        sliceRemaining = sliceRemaining[r.upperBound...]
                    } else {
                        break
                    }
                }

                searchStart = close?.upperBound ?? open.upperBound
            }
        }

        // 2. <function=...> or <function name="..."> tags
        // e.g. <function=file_read>{"path": "foo"}</function>
        var funcSearchStart = text.startIndex
        while funcSearchStart < text.endIndex {
            guard let funcRange = text.range(of: "<function", options: .caseInsensitive, range: funcSearchStart..<text.endIndex) else {
                break
            }
            let remainder = text[funcRange.upperBound...]
            guard let tagEnd = remainder.firstIndex(of: ">") else { break }
            let tagHeader = remainder[..<tagEnd].trimmingCharacters(in: .whitespaces)

            var extractedToolId: String? = nil
            if tagHeader.hasPrefix("=") {
                extractedToolId = String(tagHeader.dropFirst()).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
            } else if let nameRange = tagHeader.range(of: "name=", options: .caseInsensitive) {
                let afterName = tagHeader[nameRange.upperBound...].trimmingCharacters(in: .whitespaces)
                extractedToolId = afterName.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t\n\r"))
            }

            let afterTag = remainder[remainder.index(after: tagEnd)...]
            let closeTag = text.range(of: "</function>", options: .caseInsensitive, range: tagEnd..<text.endIndex)
            let bodySlice = closeTag != nil ? text[text.index(after: tagEnd)..<closeTag!.lowerBound] : afterTag

            if let toolId = extractedToolId, !toolId.isEmpty,
               let data = balancedJSON(in: bodySlice) {
                if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    let args = (json["arguments"] ?? json["parameters"] ?? json["input"]) as? [String: Any] ?? json
                    let parsed = (toolId: toolId, arguments: args)
                    if !results.contains(where: { $0.toolId == parsed.toolId && NSDictionary(dictionary: $0.arguments).isEqual(to: parsed.arguments) }) {
                        results.append(parsed)
                    }
                }
            }

            funcSearchStart = closeTag?.upperBound ?? remainder.index(after: tagEnd)
        }

        // 3. Fenced code blocks (when not part of a documentation/example explanation)
        if !isDocExample {
            let lines = text.components(separatedBy: .newlines)
            var insideFence = false
            var fenceContent = ""
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("```") {
                    if insideFence {
                        let trimmedContent = fenceContent.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let data = balancedJSON(in: trimmedContent[...]),
                           let parsed = decodeToolCallData(data) {
                            if !results.contains(where: { $0.toolId == parsed.toolId && NSDictionary(dictionary: $0.arguments).isEqual(to: parsed.arguments) }) {
                                results.append(parsed)
                            }
                        } else if trimmedContent.uppercased().contains("TOOL_CALL") {
                            if let toolCallRange = trimmedContent.range(of: "TOOL_CALL", options: .caseInsensitive) {
                                let after = trimmedContent[toolCallRange.upperBound...].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":")))
                                if let data = balancedJSON(in: after[...]),
                                   let parsed = decodeToolCallData(data) {
                                    if !results.contains(where: { $0.toolId == parsed.toolId && NSDictionary(dictionary: $0.arguments).isEqual(to: parsed.arguments) }) {
                                        results.append(parsed)
                                    }
                                }
                            }
                        }
                        fenceContent = ""
                        insideFence = false
                    } else {
                        insideFence = true
                        fenceContent = ""
                    }
                    continue
                }
                if insideFence {
                    fenceContent += line + "\n"
                }
            }
        }

        // 4. Standalone TOOL_CALL or TOOL_CALL: lines in text (outside code fences)
        var insideCodeFence = false
        let lines = text.components(separatedBy: .newlines)
        var lineIndex = 0
        while lineIndex < lines.count {
            let line = lines[lineIndex]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") {
                insideCodeFence.toggle()
                lineIndex += 1
                continue
            }
            if !insideCodeFence, trimmed.uppercased().hasPrefix("TOOL_CALL") {
                var suffix = trimmed.dropFirst("TOOL_CALL".count)
                if suffix.first == ":" {
                    suffix = suffix.dropFirst()
                }
                let remainder = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
                if remainder.isEmpty {
                    // TOOL_CALL\n{...}
                    if lineIndex + 1 < lines.count {
                        let nextLines = lines[(lineIndex + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                        if let data = balancedJSON(in: nextLines[...]),
                           let parsed = decodeToolCallData(data) {
                            if !results.contains(where: { $0.toolId == parsed.toolId && NSDictionary(dictionary: $0.arguments).isEqual(to: parsed.arguments) }) {
                                results.append(parsed)
                            }
                        }
                    }
                } else {
                    // TOOL_CALL {...} or TOOL_CALL: {...}
                    if let data = balancedJSON(in: remainder[...]),
                       let parsed = decodeToolCallData(data) {
                        if let payload = String(data: data, encoding: .utf8), remainder.trimmingCharacters(in: .whitespacesAndNewlines) == payload.trimmingCharacters(in: .whitespacesAndNewlines) {
                            if !results.contains(where: { $0.toolId == parsed.toolId && NSDictionary(dictionary: $0.arguments).isEqual(to: parsed.arguments) }) {
                                results.append(parsed)
                            }
                        }
                    }
                }
            }
            lineIndex += 1
        }

        return results
    }

    public nonisolated static func parseToolCall(in text: String) -> (toolId: String, arguments: [String: Any])? {
        parseToolCalls(in: text).first
    }

    /// True when the text contains the tool-call channel but its payload could
    /// not be read. Such a turn is an invalid call (refused, corrected), never
    /// an answer: printing it would leak protocol text and executing it would
    /// be guesswork.
    public nonisolated static func containsToolCallChannel(_ text: String) -> Bool {
        if !parseToolCalls(in: text).isEmpty {
            return true
        }
        var insideCodeFence = false
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") {
                insideCodeFence.toggle()
                continue
            }
            if !insideCodeFence, trimmed.uppercased().hasPrefix("TOOL_CALL") {
                return true
            }
        }
        for tag in ["tool_call", "function_call", "tool_calls", "function_calls", "function="] {
            if text.range(of: "<\(tag)", options: .caseInsensitive) != nil {
                return true
            }
        }
        return false
    }

    private nonisolated static func decodeToolCallData(_ data: Data) -> (toolId: String, arguments: [String: Any])? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }

        // Support { "tool": "..." } or { "name": "..." } or { "function": "..." }
        guard let toolId = (json["tool"] ?? json["name"] ?? json["function"]) as? String,
              !toolId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        // Support { "arguments": { ... } } or { "parameters": { ... } } or { "input": { ... } }
        let rawArgs: [String: Any]
        if let argsObj = (json["arguments"] ?? json["parameters"] ?? json["input"]) as? [String: Any] {
            rawArgs = argsObj
        } else if let argsStr = (json["arguments"] ?? json["parameters"] ?? json["input"]) as? String,
                  let parsed = (try? JSONSerialization.jsonObject(with: Data(argsStr.utf8))) as? [String: Any] {
            rawArgs = parsed
        } else {
            var filtered = json
            filtered.removeValue(forKey: "tool")
            filtered.removeValue(forKey: "name")
            filtered.removeValue(forKey: "function")
            rawArgs = filtered
        }
        return (toolId.trimmingCharacters(in: .whitespacesAndNewlines), rawArgs)
    }

    /// Finds the balanced `{...}` JSON substring starting at the first `{` in `text`.
    private nonisolated static func balancedJSON(in text: Substring) -> Data? {
        guard let firstBrace = text.firstIndex(of: "{") else { return nil }
        let slice = text[firstBrace...]
        var depth = 0
        var inString = false
        var escaped = false

        for (offset, char) in slice.enumerated() {
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
                    let endIndex = slice.index(slice.startIndex, offsetBy: offset + 1)
                    return Data(slice[slice.startIndex..<endIndex].utf8)
                }
            }
        }
        return nil
    }
}
