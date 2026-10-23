import XCTest
@testable import Locally

/// The builder assembles prompts from the context index only: a
/// counts-only directory plus the retrieved, budgeted excerpts. These
/// tests pin that contract for both modes — including that Chat mode can
/// never receive project context/memory, and that an overfed retrieved
/// bundle is truncated to the mode's cap.
final class ModelContextBuilderTests: XCTestCase {

    private let directoryFixture = """
    [Context Directory]
    Tools: 5 across General, File Reading.
    System assets: 2. Skills: 3. Custom prompt chunks: 1.
    """

    func testChatModePromptCarriesDirectoryAndRetrievedExcerpts() {
        let prompt = ModelContextBuilder.build(
            ModelContextBuilder.Input(
                isAgentMode: false,
                indexDirectory: directoryFixture,
                retrievedContext: """
                [Retrieved Context]
                ### Retrieved custom instructions — set by the user, follow them
                Custom instructions excerpt (Global):
                GLOBAL-CUSTOM-MARKER
                ### Retrieved skill excerpts
                ### Skill: Code Review
                REVIEW-INSTRUCTIONS-MARKER
                """,
                thinkingEnabled: true,
                thinkingBudget: "medium",
                modelDisplayName: "Qwen Test"
            )
        )

        XCTAssertTrue(prompt.contains("[Context Directory]"))
        XCTAssertTrue(prompt.contains("GLOBAL-CUSTOM-MARKER"))
        XCTAssertTrue(prompt.contains("REVIEW-INSTRUCTIONS-MARKER"))
        // Chat mode: tools are not executed, and the prompt points the
        // user at Agent mode instead of listing tools or skills.
        XCTAssertTrue(prompt.contains("Chat mode"))
        XCTAssertTrue(prompt.contains("switch to Agent mode"))
        // The thinking instruction must name the exact tags ThinkingModelUI parses.
        XCTAssertTrue(prompt.contains("<thinking>"))
        XCTAssertTrue(prompt.contains("</thinking>"))
    }

    func testAgentModePromptCarriesRetrievedToolSchema() {
        let prompt = ModelContextBuilder.build(
            ModelContextBuilder.Input(
                isAgentMode: true,
                indexDirectory: directoryFixture,
                retrievedContext: """
                [Retrieved Context]
                ### Retrieved tool schemas (call with the TOOL_CALL format)
                - `calculator`: Calculator
                  Description: Evaluate an arithmetic expression.
                  Arguments:
                    * `expression` (string, required): The arithmetic expression.
                """
            )
        )

        XCTAssertTrue(prompt.contains("AGENT MODE"))
        XCTAssertTrue(prompt.contains("TOOL_CALL"))
        XCTAssertTrue(prompt.contains("expression"))
    }

    func testEmptyInputStillIdentifiesTheApp() {
        let prompt = ModelContextBuilder.build(ModelContextBuilder.Input())
        XCTAssertTrue(prompt.contains("Locally"))
    }

    func testEveryPromptCarriesTheToolSecrecyRule() {
        let chat = ModelContextBuilder.build(ModelContextBuilder.Input(isAgentMode: false))
        let agent = ModelContextBuilder.build(ModelContextBuilder.Input(isAgentMode: true))
        XCTAssertTrue(chat.contains("Never Reveal Tool Plumbing"))
        XCTAssertTrue(agent.contains("Never Reveal Tool Plumbing"))
    }

    func testProjectContextIsIncludedInAgentModeWhenProvided() {
        let prompt = ModelContextBuilder.build(
            ModelContextBuilder.Input(
                isAgentMode: true,
                projectContext: "[Active Project — Demo]\nProject memory marker"
            )
        )
        XCTAssertTrue(prompt.contains("[Active Project — Demo]"))
        XCTAssertTrue(prompt.contains("Project memory marker"))
    }

    func testProjectContextIsDroppedInChatModeEvenWhenProvided() {
        // The Memory system is Agent-mode only: the builder refuses a
        // project block in Chat mode even if a caller passes one.
        let prompt = ModelContextBuilder.build(
            ModelContextBuilder.Input(
                isAgentMode: false,
                projectContext: "[Active Project — Demo]\nSECRET-PROJECT-MEMORY-MARKER"
            )
        )
        XCTAssertFalse(prompt.contains("SECRET-PROJECT-MEMORY-MARKER"))
        XCTAssertFalse(prompt.contains("[Active Project — Demo]"))
    }

    func testRetrievedContextIsTruncatedToTheModeBudget() {
        let oversized = String(repeating: "retrieved excerpt text that goes on and on. ", count: 400)

        let chat = ModelContextBuilder.build(
            ModelContextBuilder.Input(isAgentMode: false, retrievedContext: oversized)
        )
        XCTAssertTrue(chat.contains("truncated to this mode's token budget"))
        // 10k+ characters went in; the prompt must stay near the 600-token
        // Chat cap (2,400 chars) plus the fixed identity/secrecy sections.
        XCTAssertLessThan(chat.count, 600 * 4 + 1_600)

        let agent = ModelContextBuilder.build(
            ModelContextBuilder.Input(isAgentMode: true, retrievedContext: oversized)
        )
        XCTAssertTrue(agent.contains("truncated to this mode's token budget"))
        XCTAssertLessThan(agent.count, 1_600 * 4 + 1_600)
    }
}
