import XCTest
@testable import Locally

/// The context index is the token-optimization contract: catalogs are
/// indexed locally, prompts get a counts-only directory plus a small
/// budgeted bundle of retrieved excerpts, and project memory can never
/// enter a Chat-mode index. These tests pin that contract.
final class ContextIndexManagerTests: XCTestCase {

    // MARK: - Fixtures

    private struct GitHistoryFixtureTool: AssistTool {
        let id = "git_history"
        let name = "Git History"
        let description = "Show the git commit history and log for the repository."
        let capability = ToolCapability.gitOperations
        let riskLevel = ToolRiskLevel.safeRead
        var parametersSchema: JSONSchema {
            JSONSchema(
                type: "object",
                description: "Shows git history.",
                properties: ["path": JSONSchema(type: "string", description: "Repository path.")],
                required: ["path"]
            )
        }
        func execute(input: [String: Any], context: AssistContext) async throws -> AssistToolResult {
            .success("unused")
        }
    }

    private func skill(name: String, markdown: String, active: Bool) -> AgentSkill {
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

    private func project(memoryTexts: [String]) -> AgentProject {
        AgentProject(
            name: "Indexed",
            rootPath: "/tmp/indexed-project",
            memory: memoryTexts.enumerated().map {
                AgentProjectMemoryEntry(text: $0.element, createdAt: Date(timeIntervalSince1970: TimeInterval(1_000 + $0.offset)), kind: .fact)
            }
        )
    }

    private func makeIndex(
        mode: ContextIndexManager.Mode,
        tools: [any AssistTool] = [],
        skills: [AgentSkill] = [],
        activeSkillIDs: Set<String> = [],
        globalPrompt: String = "",
        conversationPrompt: String = "",
        project: AgentProject? = nil
    ) -> [ContextIndexManager.Entry] {
        ContextIndexManager.buildIndex(
            tools: tools,
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
            assetContent: { _ in "FULL-ASSET-BODY " + String(repeating: "asset detail ", count: 50) },
            skills: skills,
            activeSkillIDs: activeSkillIDs,
            globalCustomPrompt: globalPrompt,
            conversationCustomPrompt: conversationPrompt,
            project: project,
            mode: mode
        )
    }

    // MARK: - Index building

    func testIndexContainsEntriesPerKindInAgentMode() {
        let active = skill(name: "Review", markdown: "Review markdown", active: true)
        let entries = makeIndex(
            mode: .agent,
            tools: [CalculatorAssistTool()],
            skills: [active],
            activeSkillIDs: [active.id],
            globalPrompt: "Be terse.\n\nAlways cite files.",
            project: project(memoryTexts: ["Uses SwiftData"])
        )
        XCTAssertTrue(entries.contains { $0.kind == .tool })
        XCTAssertTrue(entries.contains { $0.kind == .systemAsset })
        XCTAssertTrue(entries.contains { $0.kind == .skill })
        XCTAssertTrue(entries.contains { $0.kind == .customPrompt })
        XCTAssertTrue(entries.contains { $0.kind == .projectMemory })
    }

    func testChatIndexContainsZeroProjectMemoryEntries() {
        let proj = project(memoryTexts: ["Uses SwiftData", "Deploy on Fridays"])
        let chatEntries = makeIndex(mode: .chat, project: proj)
        XCTAssertEqual(chatEntries.filter { $0.kind == .projectMemory }.count, 0)

        let agentEntries = makeIndex(mode: .agent, project: proj)
        XCTAssertEqual(agentEntries.filter { $0.kind == .projectMemory }.count, 2)

        // And the Chat bundle drops memory defensively even if handed
        // Agent-mode entries.
        let chatBundle = ContextIndexManager.retrievedBundle(
            entries: agentEntries, query: "SwiftData deploy", mode: .chat, hasActiveProject: true
        )
        XCTAssertFalse(chatBundle.contains("SwiftData"))
        XCTAssertFalse(chatBundle.contains("Deploy on Fridays"))
    }

    func testDuplicateCustomPromptIsIndexedOnce() {
        let entries = ContextIndexManager.customPromptEntries(global: "Same text here", conversation: "Same text here")
        XCTAssertEqual(entries.count, 1)
    }

    func testCustomPromptChunkingSplitsOnHeadingsAndParagraphs() {
        let chunks = ContextIndexManager.chunkCustomPrompt("# Rules\nBe terse.\n\n# Style\nUse lists.")
        XCTAssertEqual(chunks.count, 2)
        XCTAssertTrue(chunks[0].contains("Be terse."))
        XCTAssertTrue(chunks[1].contains("Use lists."))
    }

    // MARK: - Directory

    func testDirectoryHasCountsAndCategoriesButNoToolIDsOrSchemas() {
        let entries = makeIndex(
            mode: .agent,
            tools: [CalculatorAssistTool(), GitHistoryFixtureTool()],
            globalPrompt: "Be terse.",
            project: project(memoryTexts: ["One fact"])
        )
        let directory = ContextIndexManager.directoryText(entries: entries, mode: .agent)
        XCTAssertTrue(directory.contains("Tools: 2"))
        XCTAssertTrue(directory.contains("Version Control (Git)"))
        XCTAssertTrue(directory.contains("System assets: 1"))
        XCTAssertTrue(directory.contains("Project memory entries: 1"))
        // No tool ids, no per-item listing, no schema text.
        XCTAssertFalse(directory.contains("calculator"))
        XCTAssertFalse(directory.contains("git_history"))
        XCTAssertFalse(directory.contains("Arguments:"))
        XCTAssertFalse(directory.contains("Coding Standards"))
        XCTAssertLessThanOrEqual(ContextIndexManager.estimatedTokens(for: directory), 160)

        let chatDirectory = ContextIndexManager.directoryText(entries: entries, mode: .chat)
        XCTAssertFalse(chatDirectory.contains("Project memory"))
    }

    // MARK: - Retrieval

    func testRetrievalRanksGitToolTopAndReturnsOnlyMatches() {
        let entries = makeIndex(
            mode: .agent,
            tools: [CalculatorAssistTool(), GitHistoryFixtureTool(), AssistReadFileTool()]
        )
        let results = ContextIndexManager.search(entries: entries, query: "git commit history", kind: .tool, limit: 5)
        XCTAssertEqual(results.first?.id, "tool:git_history")

        let bundle = ContextIndexManager.retrievedBundle(
            entries: entries, query: "git commit history", mode: .agent
        )
        XCTAssertTrue(bundle.contains("git_history"))
        XCTAssertTrue(bundle.contains("Git History"))
        // Only matched entries: the calculator's schema is not along for the ride.
        XCTAssertFalse(bundle.contains("`calculator`"))
        XCTAssertFalse(bundle.contains("`file_read`"))
    }

    func testAgentBundleAlwaysIncludesCoreTools() {
        let entries = makeIndex(
            mode: .agent,
            tools: [ContextIndexSearchTool(), SystemAssetLookupAssistTool(), CalculatorAssistTool()]
        )
        let bundle = ContextIndexManager.retrievedBundle(
            entries: entries, query: "banana smoothie recipe", mode: .agent
        )
        XCTAssertTrue(bundle.contains("`context_index_search`"))
        XCTAssertTrue(bundle.contains("`system_asset_lookup`"))
    }

    func testToolSchemaBundleCapsAtTwelveTools() {
        var tools: [any AssistTool] = [ContextIndexSearchTool(), SystemAssetLookupAssistTool()]
        // Thirteen more tools that all lexically match the query.
        for index in 0..<13 {
            tools.append(skillToolFixture(index: index))
        }
        let entries = makeIndex(mode: .agent, tools: tools)
        let bundle = ContextIndexManager.toolSchemaBundle(entries: entries, query: "banana tool", hasActiveProject: false)
        let schemaBlocks = bundle.components(separatedBy: "Description:").count - 1
        XCTAssertLessThanOrEqual(schemaBlocks, ContextIndexManager.maxToolSchemasInBundle)
        XCTAssertTrue(bundle.hasPrefix("- `context_index_search`"))
        XCTAssertLessThanOrEqual(
            ContextIndexManager.estimatedTokens(for: bundle),
            ContextIndexManager.toolSchemaTokenBudget
        )
    }

    private func skillToolFixture(index: Int) -> AssistTool {
        BananaFixtureTool(index: index)
    }

    private struct BananaFixtureTool: AssistTool {
        let index: Int
        var id: String { "banana_tool_\(index)" }
        var name: String { "Banana Tool \(index)" }
        var description: String { "A banana tool for banana tasks." }
        let capability = ToolCapability.general
        let riskLevel = ToolRiskLevel.safeRead
        var parametersSchema: JSONSchema {
            JSONSchema(type: "object", description: "Banana.", properties: [:], required: [])
        }
        func execute(input: [String: Any], context: AssistContext) async throws -> AssistToolResult {
            .success("unused")
        }
    }

    func testBundleRespectsBudgetsWithOversizedFixtures() {
        let hugeSkillMarkdown = String(repeating: "skill body line of text ", count: 800) + "END-OF-HUGE-SKILL"
        let huge = skill(name: "Huge", markdown: hugeSkillMarkdown, active: true)
        let hugePrompt = (0..<40).map { "Standing paragraph \($0) with rule text that keeps going on." }.joined(separator: "\n\n")
            + "\n\nFINAL-PROMPT-TAIL-MARKER"
        let entries = makeIndex(
            mode: .agent,
            tools: [CalculatorAssistTool()],
            skills: [huge],
            activeSkillIDs: [huge.id],
            globalPrompt: hugePrompt
        )

        let chatBundle = ContextIndexManager.retrievedBundle(entries: entries, query: "hello there friend", mode: .chat)
        XCTAssertLessThanOrEqual(ContextIndexManager.estimatedTokens(for: chatBundle), ContextIndexManager.chatBundleTokenBudget)
        XCTAssertFalse(chatBundle.contains("END-OF-HUGE-SKILL"))
        XCTAssertFalse(chatBundle.contains("FINAL-PROMPT-TAIL-MARKER"))

        let agentBundle = ContextIndexManager.retrievedBundle(entries: entries, query: "hello there friend", mode: .agent)
        XCTAssertLessThanOrEqual(ContextIndexManager.estimatedTokens(for: agentBundle), ContextIndexManager.agentBundleTokenBudget)
        XCTAssertFalse(agentBundle.contains("END-OF-HUGE-SKILL"))
    }

    func testCustomPromptChunksAreRetrievedWithPriorityButCapped() {
        let prompt = "STANDING-RULE-ONE: always be terse.\n\n" + String(repeating: "filler paragraph about nothing in particular at all. ", count: 60)
        let entries = makeIndex(mode: .chat, globalPrompt: prompt)
        // A query with zero lexical overlap: the standing instructions are
        // still retrieved (priority boost), within their sub-budget.
        let bundle = ContextIndexManager.retrievedBundle(entries: entries, query: "zebra xylophone quasar", mode: .chat)
        XCTAssertTrue(bundle.contains("STANDING-RULE-ONE"))
        XCTAssertLessThanOrEqual(ContextIndexManager.estimatedTokens(for: bundle), ContextIndexManager.chatBundleTokenBudget)
    }

    func testSkillExcerptIsTruncatedWithRetrievalNote() {
        let markdown = String(repeating: "a", count: 1_100) + "MIDDLE-MARKER" + String(repeating: "b", count: 3_000) + "FAR-TAIL-MARKER"
        let active = skill(name: "Long", markdown: markdown, active: true)
        let entries = makeIndex(mode: .agent, skills: [active], activeSkillIDs: [active.id])
        let bundle = ContextIndexManager.retrievedBundle(entries: entries, query: "unrelated words here", mode: .agent)
        XCTAssertTrue(bundle.contains("Excerpt only"))
        XCTAssertFalse(bundle.contains("FAR-TAIL-MARKER"))
    }

    func testAgentBundleCapsProjectMemoryAtFiveEntries() {
        let texts = (0..<8).map { "Swift fact number \($0) about swift tooling" }
        let entries = makeIndex(mode: .agent, project: project(memoryTexts: texts))
        let bundle = ContextIndexManager.retrievedBundle(entries: entries, query: "swift fact", mode: .agent, hasActiveProject: true)
        let memoryPieces = bundle.components(separatedBy: "- [Fact]").count - 1
        XCTAssertLessThanOrEqual(memoryPieces, ContextIndexManager.maxProjectMemoryEntriesInBundle)
        XCTAssertGreaterThan(memoryPieces, 0)
    }

    func testAssetBodiesAreNeverPreInjectedOnlySummaries() {
        let entries = makeIndex(mode: .agent)
        let bundle = ContextIndexManager.retrievedBundle(entries: entries, query: "swift coding standards", mode: .agent)
        XCTAssertTrue(bundle.contains("Modern Swift guidelines."))
        XCTAssertFalse(bundle.contains("FULL-ASSET-BODY"))
    }

    // MARK: - On-demand search

    func testSearchReturnsFullToolSchemaPayload() {
        let entries = makeIndex(mode: .agent, tools: [GitHistoryFixtureTool()])
        let results = ContextIndexManager.search(entries: entries, query: "git commit history", kind: .tool)
        XCTAssertEqual(results.count, 1)
        let rendered = ContextIndexManager.renderSearchResults(results)
        XCTAssertTrue(rendered.contains("Arguments:"))
        XCTAssertTrue(rendered.contains("`path`"))
    }

    func testSearchResultsAreCappedAtTheSearchBudget() {
        let big = (0..<6).map { index in
            ContextIndexManager.Entry(
                id: "skill:big\(index)",
                kind: .skill,
                title: "Big Skill \(index)",
                description: "banana skill",
                payload: String(repeating: "banana payload text ", count: 600),
                order: index
            )
        }
        let results = ContextIndexManager.search(entries: big, query: "banana", kind: .skill, limit: 8)
        let rendered = ContextIndexManager.renderSearchResults(results)
        XCTAssertLessThanOrEqual(
            ContextIndexManager.estimatedTokens(for: rendered),
            ContextIndexManager.searchResultTokenBudget + 40 // heading allowance
        )
    }

    func testFoundationRunnerAlwaysOffersContextIndexSearch() {
        if #available(macOS 26.0, *) {
            let ids = FoundationModelAgentRunner.runToolIDs(projectID: nil, computerUseEnabled: false)
            XCTAssertTrue(ids.contains("context_index_search"))
            XCTAssertFalse(ids.contains("project_memory"))
            let withProject = FoundationModelAgentRunner.runToolIDs(projectID: UUID(), computerUseEnabled: false)
            XCTAssertTrue(withProject.contains("project_memory"))
            XCTAssertTrue(withProject.contains("context_index_search"))
        }
    }
}
