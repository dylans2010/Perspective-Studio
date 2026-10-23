import XCTest
@testable import Locally

/// The tool-execution contract, end to end:
/// registry resolution → schema validation → refusal or real execution →
/// result back to the model. Also the screenshot regression: a model that
/// narrates a debugger command must never have anything executed, must never
/// be told the action ran, and must not be allowed to repeat itself forever.
@MainActor
final class ToolExecutionLoopTests: XCTestCase {

    private var catalog: ToolCatalog {
        ToolCatalog(tools: [
            CalculatorAssistTool(),
            DateTimeAssistTool(),
            SystemAssetLookupAssistTool(),
            ContextIndexSearchTool(),
            AssistReadFileTool(),
            AssistSearchTool()
        ])
    }

    // MARK: - Registry resolution & validation

    func testRegisteredToolResolvesCaseInsensitivelyToItsRegistryID() {
        let outcome = ToolCallValidator.validate(
            toolID: "  CALCULATOR ",
            arguments: ["expression": .string("1+1")],
            catalog: catalog
        )
        guard case .accepted(let call) = outcome else {
            return XCTFail("a registered tool must resolve")
        }
        XCTAssertEqual(call.toolID, "calculator", "the canonical registry id is used, not the model's spelling")
    }

    func testUnknownToolIsRejectedBeforeExecution() {
        let outcome = ToolCallValidator.validate(
            toolID: "nsuserdebug",
            arguments: [:],
            catalog: catalog
        )
        guard case .rejected(.unknownTool(let requested)) = outcome else {
            return XCTFail("an unregistered id must be rejected, never dispatched")
        }
        XCTAssertEqual(requested, "nsuserdebug")
    }

    func testUndeclaredArgumentIsRejectedAndTheAcceptedKeysAreListed() {
        let outcome = ToolCallValidator.validate(
            toolID: "calculator",
            arguments: ["expression": .string("1+1"), "pid": .string("42")],
            catalog: catalog
        )
        guard case .rejected(.unexpectedArgument(let toolID, let key, let accepted)) = outcome else {
            return XCTFail("an undeclared argument must be rejected")
        }
        XCTAssertEqual(toolID, "calculator")
        XCTAssertEqual(key, "pid")
        XCTAssertEqual(accepted, ["expression"])
    }

    func testMissingRequiredArgumentIsRejected() {
        let outcome = ToolCallValidator.validate(toolID: "calculator", arguments: [:], catalog: catalog)
        guard case .rejected(.missingArgument(_, let key)) = outcome else {
            return XCTFail("a missing required argument must be rejected")
        }
        XCTAssertEqual(key, "expression")
    }

    func testWrongArgumentTypeIsRejected() {
        let outcome = ToolCallValidator.validate(
            toolID: "calculator",
            arguments: ["expression": .number(2)],
            catalog: catalog
        )
        guard case .rejected(.wrongArgumentType(_, let key, let expected)) = outcome else {
            return XCTFail("a mistyped argument must be rejected")
        }
        XCTAssertEqual(key, "expression")
        XCTAssertEqual(expected, "string")
    }

    func testNestedObjectArgumentsAreValidated() {
        let badType = ToolCallValidator.validate(
            toolID: "file_read",
            arguments: [
                "path": .string("README.md"),
                "lines": .object(["start": .string("abc")])
            ],
            catalog: catalog
        )
        guard case .rejected(.wrongArgumentType(_, let key, _)) = badType else {
            return XCTFail("a nested value of the wrong type must be rejected")
        }
        XCTAssertEqual(key, "lines.start")

        let undeclared = ToolCallValidator.validate(
            toolID: "file_read",
            arguments: [
                "path": .string("README.md"),
                "lines": .object(["start": .number(1), "bogus": .number(2)])
            ],
            catalog: catalog
        )
        guard case .rejected(.unexpectedArgument(_, let nestedKey, _)) = undeclared else {
            return XCTFail("an undeclared nested key must be rejected")
        }
        XCTAssertEqual(nestedKey, "lines.bogus")
    }

    func testStringifiedNestedObjectIsAcceptedAndValidated() {
        let outcome = ToolCallValidator.validate(
            toolID: "file_read",
            arguments: [
                "path": .string("README.md"),
                "lines": .string("{\"start\": 1, \"end\": 20}")
            ],
            catalog: catalog
        )
        guard case .accepted = outcome else {
            return XCTFail("a JSON-stringified nested argument is a dispatch quirk, not a schema violation")
        }

        let badKey = ToolCallValidator.validate(
            toolID: "file_read",
            arguments: [
                "path": .string("README.md"),
                "lines": .string("{\"bogus\": 1}")
            ],
            catalog: catalog
        )
        guard case .rejected(.unexpectedArgument(_, "lines.bogus", _)) = badKey else {
            return XCTFail("a stringified object is still checked key by key")
        }
    }

    func testNumericStringIsAcceptedForANumberArgument() {
        let outcome = ToolCallValidator.validate(
            toolID: "context_index_search",
            arguments: ["query": .string("file read"), "limit": .string("3")],
            catalog: catalog
        )
        guard case .accepted = outcome else {
            return XCTFail("a numeric string for a number argument is a coercion, not a schema violation")
        }
    }

    func testJSONNumbersDoNotDecodeAsBooleans() {
        // JSONSerialization hands numbers back as NSNumber, which bridges to
        // Bool on Apple platforms. Unchecked, `{"limit": 1}` became `true`.
        XCTAssertEqual(AnyCodableValue(any: NSNumber(value: 1)), .number(1))
        XCTAssertEqual(AnyCodableValue(any: NSNumber(value: 0)), .number(0))
        XCTAssertEqual(AnyCodableValue(any: true), .bool(true))
    }

    func testCapabilityLookupReadsTheLiveRegistry() async throws {
        let result = try await AssistToolCapabilityLookupTool().execute(
            input: ["toolId": "file_read"],
            context: AssistContext(workspaceRoot: URL.documentsDirectory)
        )
        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertTrue(result.output.contains("Read File"))
    }

    func testCapabilityLookupReportsAnUnknownIDWithTheRegisteredSet() async throws {
        let result = try await AssistToolCapabilityLookupTool().execute(
            input: ["toolId": "nsuserdebug"],
            context: AssistContext(workspaceRoot: URL.documentsDirectory)
        )
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.output.contains("file_read"), "the live registry's ids are listed")
    }

    // MARK: - Classification (the screenshot regression)

    private let debuggerNarration = """
    I'll use `nsuserdebug` to attach to the Xcode process and inspect the main thread.

    ```bash
    nsuserdebug --attach 18432
    ```
    """

    func testNarratedDebuggerCommandIsProseNotAToolCall() {
        let decision = AntigravityLoopEngine.decide(turnText: debuggerNarration, catalog: catalog)
        guard case .finalAnswer = decision else {
            return XCTFail("a command written in prose or a code block is never an invocation")
        }
        XCTAssertTrue(AntigravityLoopEngine.describesPendingAction(debuggerNarration))
    }

    func testOrdinaryFutureTenseProseIsNotNarration() {
        XCTAssertFalse(AntigravityLoopEngine.describesPendingAction("I will now summarize the three findings above."))
        XCTAssertFalse(AntigravityLoopEngine.describesPendingAction("Let me know if you want the full diff."))
        XCTAssertTrue(AntigravityLoopEngine.describesPendingAction("Let me run the build first."))
    }

    func testFencedJSONNamingARealToolIsNotACall() {
        let block = """
        Here is the payload shape:
        ```json
        {"tool": "calculator", "arguments": {"expression": "1+1"}}
        ```
        """
        switch AntigravityLoopEngine.decide(turnText: block, catalog: catalog) {
        case .finalAnswer:
            break
        case .callTool, .invalidToolCall:
            XCTFail("a fenced JSON example must never be parsed as a call")
        }
    }

    func testUnknownIDInTheToolChannelIsRefused() {
        let decision = AntigravityLoopEngine.decide(
            turnText: "TOOL_CALL {\"tool\": \"nsuserdebug\", \"arguments\": {\"pid\": \"42\"}}",
            catalog: catalog
        )
        guard case .invalidToolCall(let requested, let rejection) = decision else {
            return XCTFail("an unregistered id must be refused at classification")
        }
        XCTAssertEqual(requested, "nsuserdebug")
        XCTAssertEqual(rejection, .unknownTool("nsuserdebug"))
    }

    func testSchemalessLegacyClassificationStillResolvesKnownIDs() {
        let decision = AntigravityLoopEngine.decide(
            turnText: "TOOL_CALL {\"tool\": \"calculator\", \"arguments\": {}}",
            knownToolIDs: ["calculator"]
        )
        guard case .callTool(let toolID, _) = decision else {
            return XCTFail("a registered id must still classify as a call")
        }
        XCTAssertEqual(toolID, "calculator")

        switch AntigravityLoopEngine.decide(
            turnText: "TOOL_CALL {\"tool\": \"nsuserdebug\", \"arguments\": {}}",
            knownToolIDs: ["calculator"]
        ) {
        case .invalidToolCall:
            break
        case .callTool, .finalAnswer:
            XCTFail("an unregistered id must never classify as a call")
        }
    }

    func testMalformedToolChannelIsAnInvalidCallNotAnAnswer() {
        switch AntigravityLoopEngine.decide(turnText: "TOOL_CALL {\"tool\": \"calculator\"", catalog: catalog) {
        case .invalidToolCall(_, let rejection):
            XCTAssertEqual(rejection, .malformedCall)
        case .finalAnswer, .callTool:
            XCTFail("an unreadable invocation must not become a message")
        }
    }

    func testObservationPromptMarksFailuresAsFailures() {
        let prompt = AntigravityLoopEngine.observationPrompt(
            toolID: "file_read",
            output: "Error: no such file",
            success: false
        )
        XCTAssertTrue(prompt.contains("FAILED"))
        XCTAssertFalse(prompt.contains("file_read"))
    }

    // MARK: - Executor

    func testExecutorReturnsTheRealToolResult() async {
        let outcome = await ToolExecutor.execute(
            tool: CalculatorAssistTool(),
            arguments: ["expression": .string("6*7")],
            context: AssistContext(workspaceRoot: URL.documentsDirectory),
            timeout: .seconds(5)
        )
        XCTAssertTrue(outcome.result.success)
        XCTAssertEqual(outcome.result.output, "6*7 = 42")
        XCTAssertFalse(outcome.timedOut)
        XCTAssertGreaterThanOrEqual(outcome.duration, 0)
    }

    func testExecutorBoundsASlowToolAndReportsFailure() async {
        let outcome = await ToolExecutor.execute(
            tool: SlowStubTool(delay: .seconds(2)),
            arguments: [:],
            context: AssistContext(workspaceRoot: URL.documentsDirectory),
            timeout: .milliseconds(80)
        )
        XCTAssertTrue(outcome.timedOut)
        XCTAssertFalse(outcome.result.success)
        XCTAssertEqual(outcome.result.output.contains("did not finish"), true)
    }

    // MARK: - Harness integration (real tool implementations)

    func testOneToolCallThenAFinalAnswer() async {
        let mock = ScriptedModelBackend(script: [
            "TOOL_CALL {\"tool\": \"calculator\", \"arguments\": {\"expression\": \"2+2\"}}",
            "It is 4."
        ])
        let harness = AntigravityAgentHarness()
        let outcome = await harness.run(
            prompt: "calculate 2+2 in the project notes",
            modelID: "mock/model",
            backend: mock
        )

        XCTAssertTrue(outcome.success, outcome.error ?? "")
        XCTAssertEqual(outcome.answer, "It is 4.")
        XCTAssertEqual(harness.toolCallRecords.count, 1)
        XCTAssertEqual(harness.toolCallRecords.first?.toolID, "calculator")
        XCTAssertEqual(harness.toolCallRecords.first?.status, .completed)
        XCTAssertEqual(mock.prompts.count, 2)
        XCTAssertTrue(
            mock.prompts[1].contains("2+2 = 4"),
            "the real tool result must reach the model's next turn"
        )
    }

    func testRepeatedNarrationStopsWithoutExecutingAnything() async {
        let mock = ScriptedModelBackend(script: [debuggerNarration, debuggerNarration])
        let harness = AntigravityAgentHarness()
        let outcome = await harness.run(
            prompt: "debug the freeze in my Xcode project",
            modelID: "mock/model",
            backend: mock
        )

        XCTAssertFalse(outcome.success, "a described action is not a completed task")
        XCTAssertTrue(harness.toolCallRecords.isEmpty, "nothing may execute for a narration")
        XCTAssertFalse(outcome.answer.contains("nsuserdebug"), "the invented id is not repeated back to the user")
        XCTAssertTrue(outcome.answer.contains("kept describing actions"))
        XCTAssertFalse(outcome.steps.contains { $0.kind == .toolCall })
    }

    func testRepeatedUnknownToolRequestsAreRefusedAndStopped() async {
        let mock = ScriptedModelBackend(script: [
            "TOOL_CALL {\"tool\": \"nsuserdebug\", \"arguments\": {\"pid\": \"42\"}}",
            "TOOL_CALL {\"tool\": \"nsuserdebug\", \"arguments\": {\"pid\": \"42\"}}"
        ])
        let harness = AntigravityAgentHarness()
        let outcome = await harness.run(
            prompt: "debug the crash in my project",
            modelID: "mock/model",
            backend: mock
        )

        XCTAssertFalse(outcome.success)
        XCTAssertTrue(harness.toolCallRecords.isEmpty)
        XCTAssertTrue(outcome.answer.contains("cannot execute"))
        XCTAssertFalse(outcome.answer.contains("nsuserdebug"))
    }

    func testInvalidArgumentsAreCorrectedThenTheRealCallRuns() async {
        let mock = ScriptedModelBackend(script: [
            "TOOL_CALL {\"tool\": \"calculator\", \"arguments\": {\"expr\": \"2+2\"}}",
            "TOOL_CALL {\"tool\": \"calculator\", \"arguments\": {\"expression\": \"2+2\"}}",
            "Four."
        ])
        let harness = AntigravityAgentHarness()
        let outcome = await harness.run(
            prompt: "calculate 2+2 for the project",
            modelID: "mock/model",
            backend: mock
        )

        XCTAssertTrue(outcome.success, outcome.error ?? "")
        XCTAssertEqual(outcome.answer, "Four.")
        XCTAssertEqual(harness.toolCallRecords.count, 1, "the rejected call never executed")
        XCTAssertEqual(harness.toolCallRecords.first?.status, .completed)
        XCTAssertTrue(mock.prompts[1].contains("Nothing was executed"), "the model is told the call was refused")
    }

    func testToolFailureReachesTheModelAsFailureNotSuccess() async {
        let mock = ScriptedModelBackend(script: [
            "TOOL_CALL {\"tool\": \"system_asset_lookup\", \"arguments\": {\"asset_id\": \"does_not_exist\"}}",
            "I could not find that guideline."
        ])
        let harness = AntigravityAgentHarness()
        let outcome = await harness.run(
            prompt: "search the project and read the coding standards asset",
            modelID: "mock/model",
            backend: mock
        )

        XCTAssertTrue(outcome.success, outcome.error ?? "")
        XCTAssertEqual(harness.toolCallRecords.first?.status.isFailed, true)
        XCTAssertTrue(outcome.steps.contains { $0.kind == .error })
        XCTAssertFalse(outcome.steps.contains { $0.kind == .toolResult })
        XCTAssertTrue(mock.prompts[1].contains("FAILED"))
        XCTAssertTrue(mock.prompts[1].contains("not found"))
    }

    func testRepeatedParsingDoesNotExecuteTheSameCallTwice() async {
        let duplicate = "TOOL_CALL {\"tool\": \"calculator\", \"arguments\": {\"expression\": \"3*3\"}}"
        let mock = ScriptedModelBackend(script: ["\(duplicate)\n\(duplicate)", "Nine."])
        let harness = AntigravityAgentHarness()
        let outcome = await harness.run(
            prompt: "calculate 3*3 for the project",
            modelID: "mock/model",
            backend: mock
        )

        XCTAssertTrue(outcome.success)
        XCTAssertEqual(harness.toolCallRecords.count, 1, "one turn yields one execution")
    }

    func testIdenticalToolCallsAreBoundedByTheNoProgressGuard() async {
        let call = "TOOL_CALL {\"tool\": \"calculator\", \"arguments\": {\"expression\": \"2+2\"}}"
        let mock = ScriptedModelBackend(script: [call, call, call, call])
        let harness = AntigravityAgentHarness()
        let outcome = await harness.run(
            prompt: "calculate 2+2 for the project",
            modelID: "mock/model",
            backend: mock
        )

        XCTAssertFalse(outcome.success)
        XCTAssertEqual(harness.toolCallRecords.count, AntigravityLoopEngine.maxIdenticalToolExecutions)
        XCTAssertTrue(outcome.answer.contains("same step was repeated"))
    }

    func testToolExecutionLimitIsEnforced() async {
        let mock = ScriptedModelBackend(script: [
            "TOOL_CALL {\"tool\": \"calculator\", \"arguments\": {\"expression\": \"1+1\"}}",
            "TOOL_CALL {\"tool\": \"calculator\", \"arguments\": {\"expression\": \"2+2\"}}"
        ])
        let harness = AntigravityAgentHarness()
        let outcome = await harness.run(
            prompt: "calculate both sums for the project",
            modelID: "mock/model",
            maxToolExecutions: 1,
            backend: mock
        )

        XCTAssertFalse(outcome.success)
        XCTAssertEqual(harness.toolCallRecords.count, 1)
        XCTAssertTrue(outcome.answer.contains("tool limit"))
    }

    func testConversationalTurnStillWorksWithoutTools() async {
        let mock = ScriptedModelBackend(script: ["Hi! How can I help?"])
        let harness = AntigravityAgentHarness()
        let outcome = await harness.run(prompt: "hello", modelID: "mock/model", backend: mock)

        XCTAssertTrue(outcome.success)
        XCTAssertEqual(outcome.answer, "Hi! How can I help?")
        XCTAssertTrue(harness.toolCallRecords.isEmpty)
    }

    func testCancellationStopsTheRunWithoutAnAnswer() async {
        let mock = ScriptedModelBackend(script: [String(repeating: "thinking ", count: 400)], tokenDelay: .milliseconds(15))
        let harness = AntigravityAgentHarness()
        let task = Task { @MainActor in
            await harness.run(
                prompt: "debug the failing build in my project",
                modelID: "mock/model",
                backend: mock
            )
        }
        await mock.waitUntilGenerating()
        task.cancel()
        let outcome = await task.value

        XCTAssertFalse(outcome.success)
        XCTAssertTrue(outcome.answer.contains("cancelled"))
        XCTAssertTrue(harness.toolCallRecords.isEmpty)
    }
}

private extension ToolCallStatus {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// A backend that replays a scripted list of model turns. It records the
/// prompts it receives, so a test can assert what actually reached the model
/// (including real tool results) rather than trusting the loop's own summary.
private final class ScriptedModelBackend: InferenceBackend, @unchecked Sendable {
    let backendID = "scripted-test-backend"
    let displayName = "Scripted test backend"

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

    /// Suspends until the first generation starts, so a test can cancel the run
    /// deterministically instead of racing a timer.
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
                let metrics = await MainActor.run { () -> GenerationMetrics in
                    var metrics = GenerationMetrics()
                    metrics.outputTokens = response.count
                    return metrics
                }
                continuation.yield(.finished(metrics))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// A test-only tool that never finishes in time.
private struct SlowStubTool: AssistTool {
    let delay: Duration
    let id = "slow_stub"
    let name = "Slow Stub"
    let description = "Waits, for timeout tests."

    func execute(input: [String: Any], context: AssistContext) async throws -> AssistToolResult {
        try await Task.sleep(for: delay)
        return .success("finished late")
    }
}
