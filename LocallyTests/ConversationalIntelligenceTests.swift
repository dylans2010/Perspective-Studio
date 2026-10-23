import XCTest
@testable import Locally

/// Regression tests for the conversational-intelligence repair
/// (identity, capability profiles, identity retrieval).
///
/// The failures they pin, from the live app:
/// - "what is your name" could be answered with text about reading
///   project files, searching the codebase, and checking the Mac's
///   memory — there was NO authoritative identity anywhere in the
///   prompt: the identity line named the *model*, and identity
///   questions tokenize to stopwords, so no asset was ever retrieved.
/// - "what is your purpose" / "what can you help me with" retrieved
///   nothing either (same stopword problem), so models improvised a
///   capability catalog.
/// - Every model got the same prompt budget and the same assumed
///   capabilities, including 0.5B models and the ~4K-context Apple
///   model.
///
/// These tests assert semantic/structural properties of the assembled
/// context and routing — never exact model wording.
@MainActor
final class ConversationalIntelligenceTests: XCTestCase {

    // MARK: - Fixtures

    private func makeEntries(mode: ContextIndexManager.Mode = .chat) -> [ContextIndexManager.Entry] {
        ContextIndexManager.buildIndex(
            tools: [CalculatorAssistTool(), ContextIndexSearchTool(), SystemAssetLookupAssistTool()],
            assets: [
                SystemAssetDescriptor(
                    id: "assistant_identity",
                    name: "Assistant Identity",
                    filename: "assistant_identity.md",
                    topic: "Assistant Identity, Name & Purpose",
                    summary: "Authoritative identity: the assistant's name is Locally, a general-purpose AI assistant in the Locally app; the model is its engine, not its name; purpose and the rule against claiming unverified actions.",
                    tags: ["identity", "name", "purpose", "locally", "who", "call", "capabilities", "help"]
                ),
                SystemAssetDescriptor(
                    id: "coding_standards",
                    name: "Coding Standards",
                    filename: "coding_standards.md",
                    topic: "Modern Swift",
                    summary: "Modern Swift and SwiftUI guidelines.",
                    tags: ["swift", "swiftui"]
                )
            ],
            assetContent: { id in id == "assistant_identity" ? "IDENTITY-BODY name is Locally" : "CODING-BODY" },
            skills: [],
            globalCustomPrompt: "Be terse.",
            project: nil,
            mode: mode
        )
    }

    // MARK: - A. Routing of the exact reported messages

    func testExactReportedMessagesRouteCorrectly() {
        XCTAssertEqual(ConversationRouter.intent(for: "hello"), .conversational)
        XCTAssertEqual(ConversationRouter.intent(for: "hello?"), .conversational)
        XCTAssertEqual(ConversationRouter.intent(for: "hmm"), .conversational)
        // Identity / purpose / capability questions: direct — a real
        // answer with identity instructions retrieved, no tool loop,
        // and not a bare greeting pattern.
        for message in ["what is your name", "what should I call you?", "what is your purpose?", "what can you help me with?", "who are you"] {
            XCTAssertEqual(ConversationRouter.intent(for: message), .direct, message)
        }
        XCTAssertEqual(ConversationRouter.intent(for: "Explain what a SwiftUI Picker does."), .direct)
        XCTAssertEqual(ConversationRouter.intent(for: "Inspect this project and explain its architecture."), .task)
    }

    func testIdentityDetectionIsNarrow() {
        for message in ["what is your name", "what should I call you?", "what is your purpose?", "what can you help me with?", "who are you", "please introduce yourself"] {
            XCTAssertTrue(ContextIndexManager.isIdentityQuery(message), message)
        }
        for message in ["hello", "Explain what a SwiftUI Picker does.", "Inspect this project and explain its architecture.", "fix the bug in the name field", "search the project for memory leaks"] {
            XCTAssertFalse(ContextIndexManager.isIdentityQuery(message), message)
        }
    }

    // MARK: - B. Identity in the assembled prompt

    func testEveryPromptCarriesTheIdentityCore() {
        for isAgent in [false, true] {
            for intent in ConversationIntent.allCases {
                let prompt = ModelContextBuilder.build(ModelContextBuilder.Input(
                    isAgentMode: isAgent, intent: intent, modelDisplayName: "Qwen 2.5 7B"
                ))
                XCTAssertTrue(prompt.contains("Your name is Locally"), "agent=\(isAgent) intent=\(intent)")
                XCTAssertTrue(prompt.contains("engine, not your name"), "the model must be framed as the engine (agent=\(isAgent) intent=\(intent))")
                XCTAssertFalse(prompt.contains("as the model \"Qwen"), "the old model-as-identity phrasing must not return")
                XCTAssertTrue(prompt.contains("Never claim to have inspected files"), "no-unverified-action rule (agent=\(isAgent) intent=\(intent))")
            }
        }
    }

    func testIdentityAssetIsRegisteredWithFallbackContent() async {
        let manager = SystemAssetsManager.shared
        await manager.scanAssets()
        XCTAssertTrue(manager.availableAssets().contains { $0.id == "assistant_identity" })
        let content = manager.fetchAssetContent(named: "assistant_identity")
        XCTAssertTrue(content?.contains("Assistant Identity") == true)
        XCTAssertTrue(content?.contains("Locally") == true)
        XCTAssertTrue(content?.contains("name is") == true)
    }

    // MARK: - C. Identity retrieval

    func testIdentityQuestionsRetrieveTheIdentityAsset() {
        let entries = makeEntries()
        for query in ["what is your name", "what should I call you?", "what is your purpose?", "what can you help me with?"] {
            for mode in [ContextIndexManager.Mode.chat, .agent] {
                let bundle = ContextIndexManager.retrievedBundle(
                    entries: entries, query: query, mode: mode,
                    intent: ConversationRouter.intent(for: query)
                )
                XCTAssertTrue(bundle.contains("Assistant Identity"), "\(query) (\(mode))")
                XCTAssertTrue(bundle.contains("name is Locally"), "\(query) (\(mode))")
                XCTAssertFalse(bundle.contains("IDENTITY-BODY"), "asset bodies are never pre-injected (\(query))")
            }
        }
    }

    func testGreetingDoesNotRetrieveIdentityOrCodingAssets() {
        let entries = makeEntries()
        let bundle = ContextIndexManager.retrievedBundle(
            entries: entries, query: "hello", mode: .chat, intent: .conversational
        )
        XCTAssertFalse(bundle.contains("Assistant Identity"))
        XCTAssertFalse(bundle.contains("Coding Standards"))
        XCTAssertTrue(bundle.contains("Be terse."), "standing instructions still ride on a greeting")
    }

    func testSwiftUIQuestionRetrievesCodingAssetNotIdentity() {
        let entries = makeEntries()
        let bundle = ContextIndexManager.retrievedBundle(
            entries: entries, query: "Explain what a SwiftUI Picker does.", mode: .chat, intent: .direct
        )
        XCTAssertTrue(bundle.contains("Coding Standards"))
    }

    func testIdentityDiagnosticExplainsForcedRetrieval() {
        let entries = makeEntries()
        let diagnostics = ContextIndexManager.retrievalDiagnostics(
            entries: entries, query: "what is your name", mode: .chat, intent: .direct
        )
        let identity = diagnostics.first { $0.entryID == ContextIndexManager.identityEntryID }
        XCTAssertEqual(identity?.selected, true)
        XCTAssertTrue(identity?.reason.contains("identity query") == true)
    }

    func testIdentitySearchFindsTheAssetOnDemand() {
        let entries = makeEntries()
        let results = ContextIndexManager.search(entries: entries, query: "your name", kind: .systemAsset)
        XCTAssertEqual(results.first?.id, ContextIndexManager.identityEntryID)
    }

    // MARK: - D. Capability profiles

    func testAppleProfileIsConstrainedNativeAndBounded() {
        let profile = ModelCapabilityProfile.appleFoundationModels
        XCTAssertTrue(profile.isConstrained)
        XCTAssertEqual(profile.toolCalling, .nativeStructured)
        XCTAssertEqual(profile.maxContextTokens, 4_096)
        XCTAssertEqual(profile.maxOutputTokens, GenerationDefaults.maxAppleModelOutputTokens)
        XCTAssertEqual(ModelCapabilityProfile.profile(forModelID: AppleFoundationModel.modelID), profile)
    }

    func testMLXProfilesParseSizeAndScaleByCapability() {
        let small = ModelCapabilityProfile.mlx(modelID: "mlx-community/Qwen2.5-0.5B-Instruct-4bit")
        XCTAssertEqual(small.parameterCountB, 0.5)
        XCTAssertTrue(small.isConstrained)
        XCTAssertEqual(small.toolCalling, .textProtocol)
        XCTAssertEqual(small.bundleBudgetScale, 0.5)
        XCTAssertNil(small.maxContextTokens, "unknown context stays unknown, never guessed")

        let large = ModelCapabilityProfile.mlx(modelID: "mlx-community/Llama-3.1-8B-Instruct-4bit")
        XCTAssertEqual(large.parameterCountB, 8.0)
        XCTAssertFalse(large.isConstrained)
        XCTAssertEqual(large.bundleBudgetScale, 1.0)
        XCTAssertTrue(large.toolCallingIsReliable)

        let tiny = ModelCapabilityProfile.mlx(modelID: "mlx-community/gemma-3-270m-it-4bit")
        XCTAssertEqual(tiny.parameterCountB ?? 0, 0.27, accuracy: 0.001)
        XCTAssertTrue(tiny.isConstrained)

        let unknownSize = ModelCapabilityProfile.mlx(modelID: "mlx-community/SomeModel-Instruct")
        XCTAssertNil(unknownSize.parameterCountB)
        XCTAssertFalse(unknownSize.isConstrained, "unknown size must not be treated as constrained on a guess")
    }

    func testConstrainedModelGetsShortCoreAndTighterBundle() {
        let longBundle = String(repeating: "retrieved excerpt text ", count: 400)
        let full = ModelContextBuilder.build(ModelContextBuilder.Input(
            isAgentMode: false, intent: .direct, retrievedContext: longBundle
        ))
        let constrained = ModelContextBuilder.build(ModelContextBuilder.Input(
            isAgentMode: false,
            capability: ModelCapabilityProfile.mlx(modelID: "mlx-community/Qwen2.5-1.5B-Instruct-4bit"),
            intent: .direct, retrievedContext: longBundle
        ))
        XCTAssertTrue(constrained.contains("Small Model"))
        XCTAssertFalse(full.contains("Small Model"))
        XCTAssertLessThan(constrained.count, full.count, "a constrained model's bundle cap must actually shrink the prompt")
    }

    func testUnknownProfileChangesNothing() {
        let prompt = ModelContextBuilder.build(ModelContextBuilder.Input(
            isAgentMode: false, capability: .unknown, intent: .direct, retrievedContext: "some excerpt"
        ))
        XCTAssertFalse(prompt.contains("Small Model"))
        XCTAssertTrue(prompt.contains("some excerpt"))
    }
}
