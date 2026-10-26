import XCTest
@testable import Locally

/// Regression tests for the conversation-quality repair.
///
/// The failure they pin: a simple greeting ("hello there") was routed
/// through full index retrieval and a tool loop whose prompt demanded a
/// comprehensive structured response, so models recited capability
/// catalogs as dozens of bullet points, echoed internal instructions
/// ("Response Style: Write your final answer below the tags."), and
/// surfaced the agent loop's internal "[Draft answer withheld …]"
/// history marker as "[Answer withheld]". These tests verify the
/// routing, retrieval, prompt-assembly, parser, and rendering behavior
/// structurally — with controlled inputs, not output-length vibes.
@MainActor
final class ConversationQualityTests: XCTestCase {

    // MARK: - Fixtures

    private func skill(name: String, markdown: String) -> AgentSkill {
        AgentSkill(
            id: "/tmp/skills/\(name)",
            name: name,
            description: "Description of \(name)",
            source: .custom,
            folderURL: URL(fileURLWithPath: "/tmp/skills/\(name)"),
            instructionPreview: "Description of \(name)",
            fullMarkdown: markdown,
            tags: ["Workflow"]
        )
    }

    private func makeEntries(
        mode: ContextIndexManager.Mode = .agent,
        activeSkill: AgentSkill? = nil,
        globalPrompt: String = "Be terse."
    ) -> [ContextIndexManager.Entry] {
        ContextIndexManager.buildIndex(
            tools: [CalculatorAssistTool(), ContextIndexSearchTool(), SystemAssetLookupAssistTool()],
            assets: [
                SystemAssetDescriptor(
                    id: "coding_standards",
                    name: "Coding Standards",
                    filename: "coding_standards.md",
                    topic: "Modern Swift",
                    summary: "Modern Swift guidelines.",
                    tags: ["swift"]
                )
            ],
            assetContent: { _ in "FULL-ASSET-BODY secret asset text" },
            skills: activeSkill.map { [$0] } ?? [],
            activeSkillIDs: activeSkill.map { [$0.id] } ?? [],
            globalCustomPrompt: globalPrompt,
            project: nil,
            mode: mode
        )
    }

    // MARK: - A. Router: simple conversation

    func testGreetingsAreConversational() {
        for message in ["hello", "hello there", "Hello!", "hey", "hi there", "good morning", "hello how are you"] {
            XCTAssertEqual(ConversationRouter.intent(for: message), .conversational, message)
        }
    }

    func testThanksAndAcknowledgementsAreConversational() {
        for message in ["thanks", "thank you so much", "ok", "sounds good", "perfect", "got it"] {
            XCTAssertEqual(ConversationRouter.intent(for: message), .conversational, message)
        }
    }

    func testGreetingPlusTaskIsNotConversational() {
        XCTAssertEqual(ConversationRouter.intent(for: "hello, can you read this file?"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "hello, please fix the crash in the app"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "hi, what is the capital of France?"), .direct)
    }

    func testShortMessagesAreNotAutomaticallyGreetings() {
        XCTAssertNotEqual(ConversationRouter.intent(for: "why?"), .conversational)
        XCTAssertNotEqual(ConversationRouter.intent(for: "and then?"), .conversational)
        XCTAssertEqual(ConversationRouter.intent(for: "what is the capital of France"), .direct)
        XCTAssertEqual(ConversationRouter.intent(for: "how do I write a haiku"), .direct)
        XCTAssertEqual(ConversationRouter.intent(for: "explain quantum tunneling simply"), .direct)
    }

    func testTaskSignalsRouteToTask() {
        XCTAssertEqual(ConversationRouter.intent(for: "fix the bug in ChatViewModel"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "search the project for memory leaks"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "can you read the file AGENTS.md and summarize it"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "how much memory does my Mac have"), .task)
    }

    func testPoliteImperativesAndContinuationsRouteToTask() {
        // Polite imperative prefixes followed by a task verb
        XCTAssertEqual(ConversationRouter.intent(for: "can you inspect the codebase"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "could you investigate this error"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "please examine the diff"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "would you explore this folder"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "will you audit the security"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "help me diagnose this crash"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "i need you to do the build"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "i want you to compile the project"), .task)

        // Action continuation phrases
        XCTAssertEqual(ConversationRouter.intent(for: "do it"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "do that"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "do it then"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "proceed"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "go ahead"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "execute it"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "ok, go ahead"), .task)
    }

    func testFileExtensionsAndPathsRouteToTask() {
        // Direct file extensions
        XCTAssertEqual(ConversationRouter.intent(for: "read ConversationRouter.swift"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "inspect script.py"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "check index.js"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "examine app.ts"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "audit package.json"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "review README.md"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "show notes.txt"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "check index.html"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "update style.css"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "read config.yml"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "check config.yaml"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "inspect layout.xml"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "compile main.c"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "compile main.cpp"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "read header.h"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "inspect bridge.m"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "test lib.rs"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "run server.go"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "run build.sh"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "inspect Gemfile.rb"), .task)

        // Paths with /
        XCTAssertEqual(ConversationRouter.intent(for: "inspect Locally/Services/ConversationRouter.swift"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "check src/index.js"), .task)
        XCTAssertEqual(ConversationRouter.intent(for: "read /var/log/system.log"), .task)
    }

    // MARK: - B. Retrieval gating

    func testGreetingBundleContainsOnlyStandingInstructions() {
        let active = skill(name: "Review", markdown: "Review the diff for swift style issues and cite files.")
        let entries = makeEntries(activeSkill: active)
        for mode in [ContextIndexManager.Mode.chat, .agent] {
            let bundle = ContextIndexManager.retrievedBundle(
                entries: entries, query: "hello there", mode: mode, intent: .conversational
            )
            XCTAssertTrue(bundle.contains("Be terse."), "standing user instructions survive on a greeting (\(mode))")
            XCTAssertFalse(bundle.contains("calculator"), "no tool schemas for a greeting (\(mode))")
            XCTAssertFalse(bundle.contains("context_index_search"), "no core tool schemas for a greeting (\(mode))")
            XCTAssertFalse(bundle.contains("Review the diff"), "no skill excerpts for a greeting (\(mode))")
            XCTAssertFalse(bundle.contains("Modern Swift guidelines."), "no asset summaries for a greeting (\(mode))")
            XCTAssertFalse(bundle.contains("FULL-ASSET-BODY"), "no asset bodies, ever (\(mode))")
        }
    }

    func testToolSchemaBundleIsEmptyForNonTaskIntents() {
        let entries = makeEntries()
        XCTAssertEqual(ContextIndexManager.toolSchemaBundle(entries: entries, query: "hello", intent: .conversational), "")
        XCTAssertEqual(ContextIndexManager.toolSchemaBundle(entries: entries, query: "what is 2+2", intent: .direct), "")
        let taskBundle = ContextIndexManager.toolSchemaBundle(entries: entries, query: "calculator arithmetic", intent: .task)
        XCTAssertTrue(taskBundle.contains("context_index_search"), "core tools return for genuine task turns")
    }

    func testIrrelevantActiveSkillIsNotInjected() {
        let cooking = skill(name: "Cooking", markdown: "banana smoothie recipe instructions with blender steps")
        let entries = makeEntries(activeSkill: cooking)
        let bundle = ContextIndexManager.retrievedBundle(
            entries: entries, query: "git commit history", mode: .agent, intent: .task
        )
        XCTAssertFalse(bundle.contains("smoothie"), "an active skill with no relevance to the message must not be injected")
        let relevant = ContextIndexManager.retrievedBundle(
            entries: entries, query: "banana smoothie recipe", mode: .agent, intent: .task
        )
        XCTAssertTrue(relevant.contains("smoothie"), "a relevant active skill IS retrieved")
    }

    func testSinglePayloadHitIsBelowTheRelevanceGate() {
        let entry = ContextIndexManager.Entry(
            id: "skill:chatty", kind: .skill, title: "Pottery",
            description: "Glazing techniques for clay pots.",
            payload: "hello is a word people say while glazing pottery in the studio",
            isActiveSkill: true, order: 0
        )
        XCTAssertFalse(
            ContextIndexManager.isRelevant(entry: entry, queryTokens: ContextIndexManager.tokenize("hello there friend")),
            "one common-word payload hit must not make an entry relevant"
        )
        XCTAssertTrue(
            ContextIndexManager.search(entries: [entry], query: "hello there friend", kind: .skill).isEmpty,
            "on-demand search applies the same gate"
        )
    }

    func testRetrievalDiagnosticsExplainDecisionsWithoutPayloads() {
        let entries = makeEntries()
        let diagnostics = ContextIndexManager.retrievalDiagnostics(
            entries: entries, query: "hello there", mode: .agent, intent: .conversational
        )
        let toolDiagnostic = diagnostics.first { $0.kind == .tool }
        XCTAssertEqual(toolDiagnostic?.selected, false)
        XCTAssertTrue(toolDiagnostic?.reason.contains("conversational") == true)
        let promptDiagnostic = diagnostics.first { $0.kind == .customPrompt }
        XCTAssertEqual(promptDiagnostic?.selected, true)
        for diagnostic in diagnostics {
            XCTAssertFalse(diagnostic.reason.contains("FULL-ASSET-BODY"), "diagnostics never carry payload text")
            XCTAssertFalse(diagnostic.entryID.contains("FULL-ASSET-BODY"))
        }
    }

    // MARK: - C. Prompt isolation

    func testConversationalPromptSkipsDirectoryAndCarriesConversationFirst() {
        let prompt = ModelContextBuilder.build(ModelContextBuilder.Input(
            isAgentMode: false,
            intent: .conversational,
            indexDirectory: "[Context Directory]\nTools: 110 across Files, Git.",
            retrievedContext: ""
        ))
        XCTAssertTrue(prompt.contains("Conversation First"))
        XCTAssertTrue(prompt.contains("casual conversational turn"))
        XCTAssertFalse(prompt.contains("Tools: 110"), "capability counts must not reach a greeting prompt")
        XCTAssertTrue(prompt.contains("Never Reveal Tool Plumbing"), "tool secrecy is always included")
    }

    func testEveryPromptStatesPrecedenceAndConversationFirst() {
        for intent in ConversationIntent.allCases {
            let prompt = ModelContextBuilder.build(ModelContextBuilder.Input(isAgentMode: true, intent: intent))
            XCTAssertTrue(prompt.contains("Instruction Precedence"), "intent \(intent)")
            XCTAssertTrue(prompt.contains("Conversation First"), "intent \(intent)")
        }
    }

    func testInternalMarkersNeverSurviveDisplayText() {
        let known: Set<String> = []
        XCTAssertFalse(ToolInvocationSanitizer.displayText(
            for: "[Answer withheld]\n\nHello! How can I help?", knownToolIDs: known
        ).contains("withheld"))
        XCTAssertFalse(ToolInvocationSanitizer.displayText(
            for: "[Draft answer withheld — no tools used yet]\nThe project builds.", knownToolIDs: known
        ).contains("withheld"))
        XCTAssertFalse(ToolInvocationSanitizer.displayText(
            for: "[Used a tool: Read File]\nDone.", knownToolIDs: known
        ).contains("Used a tool"))
        XCTAssertTrue(ToolInvocationSanitizer.displayText(
            for: "[Answer withheld]\n\nHello! How can I help?", knownToolIDs: known
        ).contains("Hello! How can I help?"))
    }

    func testResponseStyleInstructionEchoIsRemovedButLegitimateTextSurvives() {
        let echoed = ToolInvocationSanitizer.displayText(
            for: "Response Style: Write your final answer below the tags.\nThe answer is 42.",
            knownToolIDs: []
        )
        XCTAssertFalse(echoed.contains("below the tags"))
        XCTAssertTrue(echoed.contains("The answer is 42."))

        // Not a broad sanitizer: legitimate bracketed text and genuine
        // discussion of a style guide are untouched.
        let legitimate = "Use array[0] and see [Section 3] of the doc.\nThe guide's Response Style section covers tone."
        let cleaned = ToolInvocationSanitizer.displayText(for: legitimate, knownToolIDs: [])
        XCTAssertTrue(cleaned.contains("[Section 3]"))
        XCTAssertTrue(cleaned.contains("Response Style section covers tone."))
    }

    func testLoopEngineCleanFinalAnswerStripsWithheldMarker() {
        let cleaned = AntigravityLoopEngine.cleanFinalAnswer("[Answer withheld] Finished the task.", knownToolIDs: [])
        XCTAssertFalse(cleaned.contains("withheld"))
        XCTAssertTrue(cleaned.contains("Finished the task."))
    }

    @MainActor
    func testConversationFirstAssetIsRegistered() async {
        let manager = SystemAssetsManager.shared
        await manager.scanAssets()
        XCTAssertTrue(manager.availableAssets().contains { $0.id == "conversation_first" })
        let content = manager.fetchAssetContent(named: "conversation_first")
        XCTAssertTrue(content?.contains("Conversation First") == true)
        XCTAssertTrue(content?.contains("Match the Message") == true)
    }

    // MARK: - D. Loop, mandate, generation, parser

    func testProjectMandateDoesNotApplyToConversationalOrDirectTurns() {
        XCTAssertFalse(AgentToolPolicy.mustRejectFinalAnswer(
            toolCallsExecuted: 0, projectActive: true, requireToolUse: true, rejectionsUsed: 0, intent: .conversational
        ))
        XCTAssertFalse(AgentToolPolicy.mustRejectFinalAnswer(
            toolCallsExecuted: 0, projectActive: true, requireToolUse: true, rejectionsUsed: 0, intent: .direct
        ))
        XCTAssertTrue(AgentToolPolicy.mustRejectFinalAnswer(
            toolCallsExecuted: 0, projectActive: true, requireToolUse: true, rejectionsUsed: 0, intent: .task
        ))
    }

    func testNoProgressGuardStopsIdenticalRepeatsOnly() {
        let signature = AntigravityLoopEngine.toolCallSignature(toolID: "calculator", canonicalArguments: "{\"expression\":\"1+1\"}")
        let other = AntigravityLoopEngine.toolCallSignature(toolID: "calculator", canonicalArguments: "{\"expression\":\"2+2\"}")
        XCTAssertFalse(AntigravityLoopEngine.isNoProgressRepeat(signature: signature, previousSignatures: []))
        XCTAssertFalse(AntigravityLoopEngine.isNoProgressRepeat(signature: signature, previousSignatures: [signature]))
        XCTAssertFalse(AntigravityLoopEngine.isNoProgressRepeat(signature: other, previousSignatures: [signature, signature]))
        XCTAssertTrue(AntigravityLoopEngine.isNoProgressRepeat(signature: signature, previousSignatures: [signature, other, signature]))
    }

    func testGenerationDefaultsAreBoundedAndConversational() {
        XCTAssertEqual(GenerationDefaults.temperature(nil), GenerationDefaults.conversationalTemperature)
        XCTAssertEqual(GenerationDefaults.temperature(0.3), 0.3)
        XCTAssertGreaterThan(GenerationDefaults.maxChatOutputTokens, 0)
        XCTAssertGreaterThan(GenerationDefaults.maxAgentTurnOutputTokens, 0)
        XCTAssertLessThan(GenerationDefaults.maxAppleModelOutputTokens, GenerationDefaults.maxChatOutputTokens)
        XCTAssertTrue((0.0...1.0).contains(Double(GenerationDefaults.topP)))
    }

    func testToolCallParsingStillWorksForRealTasks() {
        let parsed = AntigravityAgentHarness.parseToolCall(in: "TOOL_CALL {\"tool\": \"calculator\", \"arguments\": {\"expression\": \"1+1\"}}")
        XCTAssertEqual(parsed?.toolId, "calculator")

        switch AntigravityLoopEngine.decide(turnText: "Hey! What can I help you with?", knownToolIDs: ["calculator"]) {
        case .finalAnswer(let answer):
            XCTAssertEqual(answer, "Hey! What can I help you with?")
        case .callTool, .callTools, .invalidToolCall:
            XCTFail("a plain greeting reply must classify as a final answer")
        }
        switch AntigravityLoopEngine.decide(turnText: "TOOL_CALL {\"tool\": \"calculator\", \"arguments\": {}}", knownToolIDs: ["calculator"]) {
        case .callTool(let toolID, _):
            XCTAssertEqual(toolID, "calculator")
        case .finalAnswer, .callTools, .invalidToolCall:
            XCTFail("a genuine tool call must still classify as a tool call — multi-step tasks keep working")
        }
    }

    func testThinkingSeparationStillWorks() {
        let split = AntigravityLoopEngine.splitThinking(from: "<thinking>quick thought</thinking>Hey there!")
        XCTAssertEqual(split.thinking, "quick thought")
        XCTAssertEqual(split.answer, "Hey there!")
    }
}
