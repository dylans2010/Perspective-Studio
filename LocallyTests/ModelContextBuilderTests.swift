import XCTest
@testable import Locally

/// The model can only recognize its tools, system assets, custom prompts,
/// and skills if they are literally in the prompt this builder produces —
/// these tests pin that contract for both modes.
final class ModelContextBuilderTests: XCTestCase {

    private func skill(name: String, markdown: String) -> AgentSkill {
        AgentSkill(
            id: "/tmp/\(name)",
            name: name,
            description: "Description of \(name)",
            source: .custom,
            folderURL: URL(fileURLWithPath: "/tmp/\(name)"),
            instructionPreview: "Description of \(name)",
            fullMarkdown: markdown,
            tags: ["Workflow"]
        )
    }

    func testChatModePromptNamesToolsAssetsCustomPromptAndSkills() {
        let active = skill(name: "Code Review", markdown: "REVIEW-INSTRUCTIONS-MARKER")
        let other = skill(name: "Web Research", markdown: "not active")
        let prompt = ModelContextBuilder.build(
            ModelContextBuilder.Input(
                globalCustomPrompt: "GLOBAL-CUSTOM-MARKER",
                conversationSystemPrompt: "CONVERSATION-CUSTOM-MARKER",
                isAgentMode: false,
                compactToolsList: "- `calculator`: Calculator — Evaluate an arithmetic expression.",
                systemAssetsIndex: "[System Assets Index]\n- coding_standards: Modern Swift guidelines",
                availableSkills: [active, other],
                activeSkills: [active],
                thinkingEnabled: true,
                thinkingBudget: "medium",
                modelDisplayName: "Qwen Test"
            )
        )

        XCTAssertTrue(prompt.contains("GLOBAL-CUSTOM-MARKER"))
        XCTAssertTrue(prompt.contains("CONVERSATION-CUSTOM-MARKER"))
        XCTAssertTrue(prompt.contains("calculator"))
        XCTAssertTrue(prompt.contains("Chat mode"))
        XCTAssertTrue(prompt.contains("coding_standards"))
        // Available skills are named; the active one's full text is included.
        XCTAssertTrue(prompt.contains("Web Research"))
        XCTAssertTrue(prompt.contains("REVIEW-INSTRUCTIONS-MARKER"))
        // The thinking instruction must name the exact tags ThinkingModelUI parses.
        XCTAssertTrue(prompt.contains("<thinking>"))
        XCTAssertTrue(prompt.contains("</thinking>"))
    }

    func testAgentModePromptCarriesFullToolSchemaAndCallFormat() {
        let prompt = ModelContextBuilder.build(
            ModelContextBuilder.Input(
                isAgentMode: true,
                fullToolsSchema: "Available Tools:\n- `calculator`: Calculator\n  Arguments:\n    * `expression` (string, required): The arithmetic expression."
            )
        )

        XCTAssertTrue(prompt.contains("AGENT MODE"))
        XCTAssertTrue(prompt.contains("TOOL_CALL"))
        XCTAssertTrue(prompt.contains("expression"))
    }

    func testDuplicateGlobalAndConversationPromptAppearsOnce() {
        let prompt = ModelContextBuilder.build(
            ModelContextBuilder.Input(
                globalCustomPrompt: "SAME-TEXT",
                conversationSystemPrompt: "SAME-TEXT"
            )
        )
        XCTAssertEqual(prompt.components(separatedBy: "SAME-TEXT").count - 1, 1)
    }

    func testEmptyInputStillIdentifiesTheApp() {
        let prompt = ModelContextBuilder.build(ModelContextBuilder.Input())
        XCTAssertTrue(prompt.contains("Locally"))
    }

    func testCompactToolsListFormat() {
        // Chat mode gets human capability names and descriptions — and NO
        // raw tool ids, which are private protocol tokens the model must
        // never learn to say (see ToolInvocationSanitizer).
        let list = ModelContextBuilder.compactToolsList(from: [CalculatorAssistTool(), DateTimeAssistTool()])
        XCTAssertTrue(list.contains("Calculator"))
        XCTAssertTrue(list.contains("Date & Time"))
        XCTAssertFalse(list.contains("calculator`"))
        XCTAssertFalse(list.contains("`date_time`"))
    }

    func testEveryPromptCarriesTheToolSecrecyRule() {
        let chat = ModelContextBuilder.build(ModelContextBuilder.Input(isAgentMode: false))
        let agent = ModelContextBuilder.build(ModelContextBuilder.Input(isAgentMode: true))
        XCTAssertTrue(chat.contains("Never Reveal Tool Plumbing"))
        XCTAssertTrue(agent.contains("Never Reveal Tool Plumbing"))
    }

    func testProjectContextIsIncludedWhenProvided() {
        let prompt = ModelContextBuilder.build(
            ModelContextBuilder.Input(
                isAgentMode: true,
                projectContext: "[Active Project — Demo]\nProject memory marker"
            )
        )
        XCTAssertTrue(prompt.contains("[Active Project — Demo]"))
        XCTAssertTrue(prompt.contains("Project memory marker"))
    }
}
