import XCTest
@testable import Locally

/// Regression tests for the critical stability repair (run identity,
/// duration limits, per-run cancellation, repeated-text termination,
/// state isolation).
///
/// The failures they pin, beyond the conversation-quality suite:
/// - Nothing bounded generation *time*: token caps existed, wall-clock
///   limits did not, so a slow or hung generation presented as the app
///   freezing with no terminal state.
/// - Cancellation was not scoped to a run: one shared engine flag was
///   reset by every new generation, the harness's stored task was never
///   assigned, and the MLX chat stream never checked cancellation at
///   all — a stop could miss its run, kill a newer one, or be ignored
///   until the model finished.
/// - A late event from a stopped/superseded run could still write into
///   the UI, because no event carried a run identity to gate on.
/// - The agent loop bounded repeated *tool calls* but not repeated
///   *text*: a model repeating the same tool-state sentence or rejected
///   draft burned the whole turn budget.
/// - The Apple-model agent path had no tool-execution cap and no
///   per-tool timeout at all (the framework drives its loop).
///
/// Pure logic is tested directly; harness behaviour is tested through a
/// scripted backend, mirroring `ToolExecutionLoopTests`. No mocked
/// result here is proof of real backend cancellation — that remains a
/// live-run check on a Mac.
@MainActor
final class GenerationStabilityTests: XCTestCase {

    // MARK: - Duration limits exist and are sane

    func testDurationLimitsAreFiniteOrderedAndPositive() {
        let chat = GenerationDefaults.maxChatGenerationDuration
        let turn = GenerationDefaults.maxAgentTurnDuration
        let run = GenerationDefaults.maxAgentRunDuration
        for limit in [chat, turn, run] {
            XCTAssertGreaterThan(GenerationRun.seconds(from: limit), 0)
            XCTAssertLessThan(GenerationRun.seconds(from: limit), 3_600, "no limit may be effectively unbounded")
        }
        XCTAssertLessThanOrEqual(turn, run, "a turn may not outlive its run")
        XCTAssertLessThanOrEqual(chat, run)
        XCTAssertGreaterThanOrEqual(GenerationDefaults.streamFlushInterval, 0.05)
        XCTAssertLessThanOrEqual(GenerationDefaults.streamFlushInterval, 0.25)
    }

    func testGenerationTimeoutErrorNamesTheLimit() {
        let error = GenerationTimeoutError(limit: .seconds(180))
        XCTAssertEqual(error.limitSeconds, 180)
        XCTAssertTrue(error.localizedDescription.contains("180s"))
        XCTAssertTrue(error.localizedDescription.contains("time limit"))
    }

    // MARK: - Run identity & deadline math

    func testRunDeadlineMath() {
        let start = Date(timeIntervalSince1970: 1_000)
        let run = GenerationRun(conversationID: nil, startedAt: start)
        XCTAssertFalse(run.hasExceeded(limit: .seconds(60), now: start.addingTimeInterval(59)))
        XCTAssertTrue(run.hasExceeded(limit: .seconds(60), now: start.addingTimeInterval(61)))
        XCTAssertEqual(run.remaining(limit: .seconds(60), now: start.addingTimeInterval(25)), .seconds(35))
        XCTAssertEqual(run.remaining(limit: .seconds(60), now: start.addingTimeInterval(90)), .zero)
        XCTAssertEqual(run.elapsed(now: start.addingTimeInterval(-5)), 0, "clock skew never makes elapsed negative")
    }

    func testEventGateAppliesOnlyTheActiveRun() {
        let runA = GenerationRun()
        let runB = GenerationRun()
        XCTAssertTrue(GenerationRun.shouldApply(eventRunID: runA.id, activeRunID: runA.id))
        XCTAssertFalse(GenerationRun.shouldApply(eventRunID: runA.id, activeRunID: runB.id),
                       "a late event from run A must be dropped once run B is active")
        XCTAssertFalse(GenerationRun.shouldApply(eventRunID: runA.id, activeRunID: nil),
                       "after a stop clears the active run, its events apply nowhere")
        XCTAssertTrue(runA.isCurrent(activeRunID: runA.id))
        XCTAssertFalse(runA.isCurrent(activeRunID: runB.id))
        XCTAssertNotEqual(runA.id, runB.id, "every run mints a unique identity")
    }

    // MARK: - Stream timeout (the anti-freeze wrapper)

    func testTokenStreamTimeoutTerminatesAHungStream() async {
        // A stream that yields once and then never finishes: without the
        // wrapper the consumer waits forever (the reported freeze).
        let hung = AsyncStream<String> { continuation in
            continuation.yield("partial")
        }
        let timed = StreamTimeout.tokens(hung, after: .milliseconds(150))
        var received: [String] = []
        var thrown: Error?
        do {
            for try await token in timed { received.append(token) }
        } catch {
            thrown = error
        }
        XCTAssertEqual(received, ["partial"], "work produced before the limit is preserved")
        XCTAssertTrue(thrown is GenerationTimeoutError, "a hung stream must end as a timeout, not silence: \(String(describing: thrown))")
    }

    func testEventStreamTimeoutPassesAFastStreamThrough() async throws {
        let fast = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            continuation.yield(.token("a"))
            continuation.yield(.token("b"))
            continuation.finish()
        }
        var tokens: [String] = []
        for try await event in StreamTimeout.events(fast, after: .seconds(30)) {
            if case .token(let token) = event { tokens.append(token) }
        }
        XCTAssertEqual(tokens, ["a", "b"])
    }

    // MARK: - Tool execution budget (Apple-model path cap)

    func testToolExecutionBudgetClaimsUpToItsLimitOnly() {
        let budget = ToolExecutionBudget(limit: 3)
        XCTAssertTrue(budget.claim())
        XCTAssertTrue(budget.claim())
        XCTAssertTrue(budget.claim())
        XCTAssertFalse(budget.claim(), "a claim past the limit executes nothing")
        XCTAssertFalse(budget.claim())
        XCTAssertEqual(budget.executedCount, 3)
        XCTAssertEqual(ToolExecutionBudget(limit: 0).limit, 1, "a budget always allows at least the first action")
    }

    // MARK: - Repeated text turns (no-progress on prose)

    func testRepeatedTextTurnDetection() {
        let first = AntigravityLoopEngine.textTurnSignature("The nsuserdebug tool was not called.")
        let sameOtherPunctuation = AntigravityLoopEngine.textTurnSignature("the nsuserdebug tool was not called!")
        let different = AntigravityLoopEngine.textTurnSignature("Let me look at the project files instead.")
        XCTAssertEqual(first, sameOtherPunctuation, "punctuation/case must not disguise a repeat")
        XCTAssertFalse(AntigravityLoopEngine.isRepeatedTextTurn(signature: first, previousSignatures: []))
        XCTAssertTrue(AntigravityLoopEngine.isRepeatedTextTurn(signature: first, previousSignatures: [first]),
                      "the same text turn a second time is no progress")
        XCTAssertFalse(AntigravityLoopEngine.isRepeatedTextTurn(signature: different, previousSignatures: [first]))
    }

    func testRepeatedRejectedDraftStopsTheRun() async {
        // Project active + tool mandate: the model answers without tools,
        // is rejected, and repeats the identical draft instead of acting.
        // Before the text guard this burned the whole turn budget.
        let draft = "This project is a small Swift app with a single window and no tests."
        let mock = StabilityScriptedBackend(script: [draft, draft, draft, draft])
        let harness = AntigravityAgentHarness()
        let project = AgentProjectsStore.shared.addProject(
            rootURL: FileManager.default.temporaryDirectory,
            name: "Stability Fixture"
        )
        defer { AgentProjectsStore.shared.removeProject(id: project.id) }
        let outcome = await harness.run(
            prompt: "describe this project",
            modelID: "mock/model",
            projectID: project.id,
            backend: mock
        )
        XCTAssertFalse(outcome.success)
        XCTAssertTrue(outcome.answer.contains("repeated the same response"),
                      "the run must stop on the repeated draft, got: \(outcome.answer)")
        XCTAssertLessThanOrEqual(mock.prompts.count, 3, "the repeat is stopped, not re-asked until the turn cap")
    }

    // MARK: - Per-run cancellation at the harness level

    func testCancellingOneRunDoesNotCancelAnother() async {
        let harness = AntigravityAgentHarness()
        let runA = UUID()
        let runB = UUID()
        XCTAssertFalse(harness.isRunCancelled(runA))
        harness.cancel(runID: runA)
        XCTAssertTrue(harness.isRunCancelled(runA))
        XCTAssertFalse(harness.isRunCancelled(runB),
                       "cancelling run A must never cancel or corrupt run B")
    }

    func testCancelledRunDispatchesNoTools() async {
        let call = "TOOL_CALL {\"tool\": \"calculator\", \"arguments\": {\"expression\": \"2+2\"}}"
        let mock = StabilityScriptedBackend(script: [call, "Four."], tokenDelay: .milliseconds(10))
        let harness = AntigravityAgentHarness()
        let runID = UUID()
        let task = Task { @MainActor in
            await harness.run(
                prompt: "calculate 2+2 for the project",
                modelID: "mock/model",
                runID: runID,
                backend: mock
            )
        }
        await mock.waitUntilGenerating()
        harness.cancel(runID: runID)
        task.cancel()
        let outcome = await task.value
        XCTAssertFalse(outcome.success)
        XCTAssertTrue(harness.toolCallRecords.isEmpty,
                      "a run cancelled while generating may not dispatch the tool call its turn was forming")
    }

    func testRunDurationLimitTerminatesGeneration() async {
        // Endless token stream, tiny run budget: the run must end with
        // the timeout as its terminal state, quickly — not when the
        // model decides to stop.
        let mock = StabilityScriptedBackend(script: [String(repeating: "word ", count: 2_000)], tokenDelay: .milliseconds(5))
        let harness = AntigravityAgentHarness()
        let started = Date.now
        let outcome = await harness.run(
            prompt: "write a very long essay for the project notes",
            modelID: "mock/model",
            runDuration: .milliseconds(200),
            turnDuration: .milliseconds(200),
            backend: mock
        )
        XCTAssertFalse(outcome.success)
        XCTAssertTrue(outcome.answer.contains("time limit"), "got: \(outcome.answer)")
        XCTAssertLessThan(Date.now.timeIntervalSince(started), 10, "the timeout must actually terminate the run")
    }

    // MARK: - History / state isolation

    func testNewConversationHistoryCarriesNoToolStateFromAnother() {
        let oldConversation = Conversation(title: "Old task")
        let errorMessage = Message(
            role: .assistant,
            content: "The nsuserdebug tool was not called, so nothing ran."
        )
        errorMessage.conversation = oldConversation
        oldConversation.messages.append(errorMessage)

        let freshConversation = Conversation(title: "New")
        let greeting = Message(role: .user, content: "hello?")
        greeting.conversation = freshConversation
        freshConversation.messages.append(greeting)

        let history = ContextSummarizationService.buildContextualPrompt(
            conversation: freshConversation,
            userMessage: "hello?"
        )
        XCTAssertFalse(history.contains { $0.content.contains("nsuserdebug") },
                       "a previous task's tool state must never serialize into a new conversation")
        XCTAssertEqual(history.filter { $0.role == "user" && $0.content == "hello?" }.count, 1,
                       "the current user message appears exactly once")
        XCTAssertEqual(history.last?.content, "hello?")
    }

    func testSameConversationFollowUpPreservesContextAndSingleUserMessage() {
        let conversation = Conversation(title: "Chat")
        let first = Message(role: .user, content: "My project is called Locally.")
        first.conversation = conversation
        conversation.messages.append(first)
        let reply = Message(role: .assistant, content: "Nice name.")
        reply.conversation = conversation
        conversation.messages.append(reply)
        let followUp = Message(role: .user, content: "what is your name")
        followUp.conversation = conversation
        conversation.messages.append(followUp)

        let history = ContextSummarizationService.buildContextualPrompt(
            conversation: conversation,
            userMessage: "what is your name"
        )
        XCTAssertTrue(history.contains { $0.content.contains("Locally") },
                      "legitimate context from the same conversation is preserved")
        XCTAssertEqual(history.filter { $0.content == "what is your name" }.count, 1,
                       "the current user message is not duplicated by history + append")
    }
}

/// A scripted backend for stability tests (mirrors the one in
/// `ToolExecutionLoopTests`, which is file-private): replays scripted
/// model turns token-chunk by token-chunk and records its prompts.
private final class StabilityScriptedBackend: InferenceBackend, @unchecked Sendable {
    let backendID = "stability-scripted-backend"
    let displayName = "Stability scripted backend"

    private let lock = NSLock()
    private nonisolated(unsafe) var script: [String]
    private nonisolated(unsafe) var promptLog: [String] = []
    private let tokenDelay: Duration
    private nonisolated(unsafe) var started = false
    private nonisolated(unsafe) var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(script: [String], tokenDelay: Duration = .zero) {
        self.script = script
        self.tokenDelay = tokenDelay
    }

    nonisolated var prompts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return promptLog
    }

    nonisolated func waitUntilGenerating() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if started {
                lock.unlock()
                continuation.resume()
                return
            }
            startWaiters.append(continuation)
            lock.unlock()
        }
    }

    private nonisolated func nextResponse(for prompt: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        promptLog.append(prompt)
        return script.isEmpty ? "" : script.removeFirst()
    }

    private nonisolated func markStarted() {
        lock.lock()
        started = true
        let waiters = startWaiters
        startWaiters = []
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    nonisolated func capabilities(for model: InstalledModel) -> BackendCapabilities {
        BackendCapabilities(
            supportsStreaming: true,
            supportsVision: false,
            supportsSystemPrompt: true,
            supportsNativeToolCalling: false
        )
    }

    nonisolated func load(model: InstalledModel) async throws -> Double { 0 }

    nonisolated func unload() async {}

    nonisolated func currentlyLoadedModelID() async -> String? { "mock/model" }

    nonisolated func stream(prompt: String, systemPrompt: String?) throws -> AsyncThrowingStream<GenerationEvent, Error> {
        let response = nextResponse(for: prompt)
        markStarted()
        let delay = tokenDelay

        return AsyncThrowingStream { continuation in
            let task = Task {
                var index = response.startIndex
                while index < response.endIndex {
                    if Task.isCancelled { break }
                    let end = response.index(index, offsetBy: 16, limitedBy: response.endIndex) ?? response.endIndex
                    continuation.yield(.token(String(response[index..<end])))
                    index = end
                    if delay > .zero { try? await Task.sleep(for: delay) }
                }
                continuation.yield(.finished(GenerationMetrics()))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
