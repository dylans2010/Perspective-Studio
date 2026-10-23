import XCTest
@testable import Locally

/// Regression tests for the 2026-10-23 Chat Quality + Agent Tool-Execution
/// repair. Each test pins one confirmed root cause:
///
/// 1. `ToolCallingService` carried a DUPLICATE tool-call decoder and
///    dispatched without the validator — it now delegates to the one
///    authoritative decoder and validates through `ToolCallValidator`.
/// 2. The agent loop classified the RAW model turn, reasoning included,
///    so a call merely considered inside <thinking> could execute — it
///    now classifies the answer portion only.
/// 3. Stripping an invocation from inside a fenced block left EMPTY
///    code fences that rendered as the screenshot's empty code blocks —
///    the sanitizer now removes empty fences (real code survives).
/// 4. The harness system prompt never named the workspace folder, so
///    "write main.swift in this directory" was ungrounded — the prompt
///    now states the workspace root and the meaning of "this directory".
/// 5. Small text-protocol models (e.g. Qwen2.5-0.5B) got no Agent-mode
///    compatibility warning — the capability profile now produces one
///    and the harness surfaces it as a run step.
/// 6. The file-creation workflow (`file_create`) had no end-to-end
///    coverage — a scripted model now drives the real loop against a
///    temporary workspace and the file is verified on disk.
///
/// All model turns are deterministic scripted fixtures (mocked model,
/// REAL loop, decoder, validator, registry, and tool implementations).
@MainActor
final class ToolCallingPipelineRepairTests: XCTestCase {

    // MARK: - 3. Empty code fences

    func testEmptyFencesLeftByStrippedInvocationsAreRemoved() {
        let text = """
        I'll create that file now:

        ```json

        ```

        ```
        TOOL_CALL {"tool": "file_create", "arguments": {"path": "main.swift"}}
        ```

        Done — the file is ready.
        """
        let display = ToolInvocationSanitizer.displayText(for: text, knownToolIDs: ["file_create"])
        XCTAssertFalse(display.contains("```"), "empty fences must not render: \(display)")
        XCTAssertTrue(display.contains("I'll create that file now:"))
        XCTAssertTrue(display.contains("Done — the file is ready."))
    }

    func testValidCodeBlocksSurviveEmptyFenceCleanup() {
        let text = """
        Here is the file:

        ```swift
        print("hello")
        ```

        And an empty one that should go:

        ```

        ```
        """
        let display = ToolInvocationSanitizer.displayText(for: text, knownToolIDs: [])
        XCTAssertTrue(display.contains("```swift\nprint(\"hello\")\n```"), display)
        XCTAssertEqual(display.components(separatedBy: "```").count - 1, 2, "only the real block's two fences remain: \(display)")
    }

    func testStripEmptyCodeFencesEdgeCases() {
        // Unterminated fence with content: kept.
        let open = "Text\n\n```swift\nprint(1)"
        XCTAssertEqual(ToolInvocationSanitizer.stripEmptyCodeFences(in: open), open)
        // Unterminated fence with no content: dropped (a trailing
        // newline from the preceding blank line may remain — the
        // display pipeline trims it).
        XCTAssertEqual(ToolInvocationSanitizer.stripEmptyCodeFences(in: "Text\n\n```").trimmingCharacters(in: .whitespacesAndNewlines), "Text")
        // No fences: unchanged.
        XCTAssertEqual(ToolInvocationSanitizer.stripEmptyCodeFences(in: "plain"), "plain")
    }

    // MARK: - 1. One authoritative decoder

    func testToolCallingServiceUsesTheAuthoritativeDecoder() {
        // The XML wrapper form only the authoritative harness decoder
        // understands (the old duplicate decoder returned nil here).
        let wrapped = "<tool_call>{\"tool\": \"calculator\", \"arguments\": {\"expression\": \"6 * 7\"}}</tool_call>"
        let call = ToolCallingService.parseToolCall(in: wrapped)
        XCTAssertEqual(call?.toolID, "calculator")
        XCTAssertEqual(call?.arguments["expression"], "6 * 7")

        // Both decoders agree on the canonical form.
        let canonical = "TOOL_CALL {\"tool\": \"calculator\", \"arguments\": {\"expression\": \"2+2\"}}"
        XCTAssertEqual(ToolCallingService.parseToolCall(in: canonical)?.toolID,
                       AntigravityAgentHarness.parseToolCall(in: canonical)?.toolId)

        // Incomplete JSON (stream fragment) parses as NO call in both.
        let fragment = "TOOL_CALL {\"tool\": \"calculator\", \"arguments\": {\"expression\": \"2+"
        XCTAssertNil(ToolCallingService.parseToolCall(in: fragment))
        XCTAssertNil(AntigravityAgentHarness.parseToolCall(in: fragment))

        // …and the loop engine treats that fragment as an invalid call,
        // never as an answer and never as an execution.
        let catalog = ToolCatalog(tools: [CalculatorAssistTool()])
        let decision = AntigravityLoopEngine.decide(turnText: fragment, catalog: catalog)
        guard case .invalidToolCall(_, .malformedCall) = decision else {
            return XCTFail("fragment must be an invalid call, got \(decision)")
        }
    }

    func testToolCallingServiceRunRejectsUnknownToolWithoutExecuting() async {
        let backend = PipelineScriptedBackend(script: [
            "TOOL_CALL {\"tool\": \"nsuserdebug\", \"arguments\": {\"pid\": \"42\"}}"
        ])
        let model = InstalledModel(id: "mock/model", displayName: "Mock", author: "mock", isVisual: false)
        let outcome = await ToolCallingService.run(prompt: "debug it", model: model, backend: backend)
        guard case .failed(let message, _) = outcome else {
            return XCTFail("an invented tool must fail the run, got \(outcome)")
        }
        XCTAssertFalse(message.contains("nsuserdebug"), "the invented id is not repeated to the user")
    }

    func testToolCallingServiceRunRejectsSchemaInvalidArguments() async {
        // `calculator` requires `expression`; `expr` is undeclared.
        let backend = PipelineScriptedBackend(script: [
            "TOOL_CALL {\"tool\": \"calculator\", \"arguments\": {\"expr\": \"2+2\"}}"
        ])
        let model = InstalledModel(id: "mock/model", displayName: "Mock", author: "mock", isVisual: false)
        let outcome = await ToolCallingService.run(prompt: "calculate", model: model, backend: backend)
        guard case .failed = outcome else {
            return XCTFail("schema-invalid arguments must fail before dispatch, got \(outcome)")
        }
    }

    // MARK: - 2. Reasoning is not a call

    func testToolCallMentionedInsideThinkingDoesNotExecute() async {
        let backend = PipelineScriptedBackend(script: [
            "<thinking>Maybe I should run TOOL_CALL {\"tool\": \"calculator\", \"arguments\": {\"expression\": \"2+2\"}} to check.</thinking>\nThe answer is 4."
        ])
        let harness = AntigravityAgentHarness()
        let outcome = await harness.run(
            prompt: "calculate 2+2 for the project",
            modelID: "mock/model",
            backend: backend
        )
        XCTAssertTrue(outcome.success, outcome.error ?? "")
        XCTAssertEqual(outcome.answer, "The answer is 4.")
        XCTAssertTrue(harness.toolCallRecords.isEmpty, "a call considered in reasoning must not execute")
    }

    // MARK: - 4 + 6. File creation, end to end in a temporary workspace

    func testFileCreationWorkflowCreatesAndVerifiesMainSwift() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appending(path: "LocallyFileCreation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let content = "import Foundation\nprint(\"Hello from main.swift\")\n"
        let call = "TOOL_CALL {\"tool\": \"file_create\", \"arguments\": {\"path\": \"main.swift\", \"content\": \"import Foundation\\nprint(\\\"Hello from main.swift\\\")\\n\"}}"
        let backend = PipelineScriptedBackend(script: [call, "Created main.swift in the workspace folder."])
        let harness = AntigravityAgentHarness()
        let outcome = await harness.run(
            prompt: "great, now write a CLI file called main.swift in this directory",
            modelID: "mock/model",
            workspaceRoot: workspace,
            backend: backend
        )

        XCTAssertTrue(outcome.success, outcome.error ?? "")
        XCTAssertEqual(harness.toolCallRecords.count, 1)
        XCTAssertEqual(harness.toolCallRecords.first?.toolID, "file_create")
        XCTAssertEqual(harness.toolCallRecords.first?.status, .completed)

        // Verified on disk — not from the model's prose.
        let fileURL = workspace.appending(path: "main.swift")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), "main.swift must exist in the requested directory")
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), content)

        // The real tool result reached the model's next turn.
        XCTAssertEqual(backend.prompts.count, 2)
        XCTAssertTrue(backend.prompts[1].contains("Created file at main.swift"), backend.prompts[1])

        // The workspace grounding reached the model's system prompt.
        XCTAssertTrue(
            backend.systemPrompts.contains { $0?.contains(workspace.path) ?? false },
            "the system prompt must name the workspace folder"
        )
        XCTAssertTrue(
            backend.systemPrompts.contains { $0?.contains("this directory") ?? false },
            "the system prompt must define what 'this directory' means"
        )
    }

    func testFileCreationFailureIsReportedNotFaked() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appending(path: "LocallyFileCreationFail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        // Pre-create the file: file_create with overwrite=false must fail.
        try "existing".write(to: workspace.appending(path: "main.swift"), atomically: true, encoding: .utf8)

        let call = "TOOL_CALL {\"tool\": \"file_create\", \"arguments\": {\"path\": \"main.swift\", \"content\": \"new\"}}"
        let backend = PipelineScriptedBackend(script: [call, "I could not create it because the file already exists."])
        let harness = AntigravityAgentHarness()
        let outcome = await harness.run(
            prompt: "write a CLI file called main.swift in this directory",
            modelID: "mock/model",
            workspaceRoot: workspace,
            backend: backend
        )
        XCTAssertTrue(harness.toolCallRecords.first?.status.isFailedStatus ?? false, "the pre-existing file must make the call fail, not silently overwrite")
        XCTAssertTrue(backend.prompts[1].contains("FAILED"), "the failure must reach the model as a failure")
        XCTAssertEqual(try String(contentsOf: workspace.appending(path: "main.swift"), encoding: .utf8), "existing", "the existing file is untouched")
        _ = outcome
    }

    // MARK: - 5. Model compatibility advisory

    func testAgentModeAdvisoryForSmallTextProtocolModel() {
        let qwen = ModelCapabilityProfile.profile(forModelID: "mlx-community/Qwen2.5-0.5B-Instruct-4bit")
        XCTAssertEqual(qwen.parameterCountB, 0.5)
        XCTAssertTrue(qwen.isConstrained)
        XCTAssertEqual(qwen.toolCalling, .textProtocol)
        XCTAssertNotNil(qwen.agentModeAdvisory)
        XCTAssertTrue(qwen.agentModeAdvisory?.contains("Chat mode is unaffected") ?? false)

        let large = ModelCapabilityProfile.profile(forModelID: "mlx-community/Qwen2.5-32B-Instruct-4bit")
        XCTAssertNil(large.agentModeAdvisory)

        XCTAssertNotNil(ModelCapabilityProfile.unknown.agentModeAdvisory)
    }

    func testCapabilityWarningStepAppearsInTaskRunTrace() async {
        let backend = PipelineScriptedBackend(script: [
            "TOOL_CALL {\"tool\": \"calculator\", \"arguments\": {\"expression\": \"2+2\"}}",
            "It is 4."
        ])
        let harness = AntigravityAgentHarness()
        let outcome = await harness.run(
            prompt: "calculate 2+2 for the project",
            modelID: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
            backend: backend
        )
        XCTAssertTrue(outcome.success, outcome.error ?? "")
        XCTAssertTrue(outcome.steps.contains { $0.title == "Model Capability Warning" },
                      "a constrained model must warn in the trace before the loop runs")
    }

    // MARK: - Chat context policy (capability question)

    func testChatCapabilityQuestionGetsNoToolSchemasOrSkillExcerpts() {
        // Fixture entries shaped like the live index: a tool, a skill,
        // and the identity asset. "what can you do?" tokenizes to
        // nothing lexical, so only the identity summary may arrive.
        let entries: [ContextIndexManager.Entry] = [
            .fixture(kind: .tool, id: "tool:file_create", title: "Create File", payload: "SCHEMA file_create path content"),
            .fixture(kind: .skill, id: "skill:coding", title: "Coding Skill", payload: "SKILL BODY write swift code"),
            .fixture(kind: .systemAsset, id: ContextIndexManager.identityEntryID, title: "Assistant Identity", payload: "Locally identity body")
        ]
        let bundle = ContextIndexManager.retrievedBundle(
            entries: entries,
            query: "what can you do?",
            mode: .chat,
            intent: .direct
        )
        XCTAssertFalse(bundle.contains("SCHEMA"), "no tool schema fragments in a Chat capability answer's context")
        XCTAssertFalse(bundle.contains("SKILL BODY"), "no skill excerpts in a Chat capability answer's context")
        XCTAssertTrue(bundle.contains("Assistant Identity"), "the identity summary is the capability answer's grounding")
    }
}

private extension ToolCallStatus {
    var isFailedStatus: Bool {
        if case .failed = self { return true }
        return false
    }
}

// MARK: - Fixture entry builder

private extension ContextIndexManager.Entry {
    static func fixture(kind: ContextIndexManager.Kind, id: String, title: String, payload: String) -> ContextIndexManager.Entry {
        ContextIndexManager.Entry(
            id: id,
            kind: kind,
            title: title,
            description: title,
            keywords: [],
            payload: payload,
            category: nil,
            isCoreTool: false,
            isActiveSkill: false,
            order: 0
        )
    }
}

/// A scripted backend that also records the system prompts it receives,
/// so tests can assert what grounding actually reached the model.
private final class PipelineScriptedBackend: InferenceBackend, @unchecked Sendable {
    let backendID = "pipeline-scripted-backend"
    let displayName = "Pipeline Scripted Backend"

    private let lock = NSLock()
    private nonisolated(unsafe) var script: [String]
    private nonisolated(unsafe) var promptLog: [String] = []
    private nonisolated(unsafe) var systemPromptLog: [String?] = []

    init(script: [String]) {
        self.script = script
    }

    nonisolated var prompts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return promptLog
    }

    nonisolated var systemPrompts: [String?] {
        lock.lock()
        defer { lock.unlock() }
        return systemPromptLog
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
        lock.lock()
        promptLog.append(prompt)
        systemPromptLog.append(systemPrompt)
        let response = script.isEmpty ? "" : script.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            let task = Task {
                var index = response.startIndex
                while index < response.endIndex {
                    if Task.isCancelled { break }
                    let end = response.index(index, offsetBy: 16, limitedBy: response.endIndex) ?? response.endIndex
                    continuation.yield(.token(String(response[index..<end])))
                    index = end
                }
                var metrics = GenerationMetrics()
                metrics.outputTokens = response.count
                continuation.yield(.finished(metrics))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
