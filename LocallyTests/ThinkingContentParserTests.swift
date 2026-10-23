import XCTest
@testable import Locally

final class ThinkingContentParserTests: XCTestCase {

    func testClosedThinkingBlockIsSeparatedFromAnswer() {
        let parsed = ThinkingContentParser.parse("<thinking>Let me work this out.</thinking>The answer is 42.")
        XCTAssertEqual(parsed.thinkingBlocks, ["Let me work this out."])
        XCTAssertEqual(parsed.answer, "The answer is 42.")
        XCTAssertFalse(parsed.isThinkingOpen)
        XCTAssertTrue(parsed.hasThinking)
    }

    func testUnclosedBlockMeansStillThinking() {
        let parsed = ThinkingContentParser.parse("<thinking>Still reason")
        XCTAssertEqual(parsed.thinkingBlocks, ["Still reason"])
        XCTAssertEqual(parsed.answer, "")
        XCTAssertTrue(parsed.isThinkingOpen)
    }

    func testPartialAnswerBeforeOpenBlockIsKept() {
        let parsed = ThinkingContentParser.parse("Intro.\n<thinking>hmm")
        XCTAssertEqual(parsed.answer, "Intro.")
        XCTAssertTrue(parsed.isThinkingOpen)
    }

    func testMultipleBlocksAndThinkAlias() {
        let parsed = ThinkingContentParser.parse("<thinking>one</thinking>middle <think>two</think> end")
        XCTAssertEqual(parsed.thinkingBlocks, ["one", "two"])
        XCTAssertEqual(parsed.answer, "middle  end".trimmingCharacters(in: .whitespaces))
        XCTAssertFalse(parsed.isThinkingOpen)
    }

    func testNoTagsPassesThrough() {
        let parsed = ThinkingContentParser.parse("Just an answer.")
        XCTAssertEqual(parsed.thinkingBlocks, [])
        XCTAssertEqual(parsed.answer, "Just an answer.")
        XCTAssertFalse(parsed.hasThinking)
    }

    func testTagsAreCaseInsensitive() {
        let parsed = ThinkingContentParser.parse("<THINKING>loud</THINKING>quiet")
        XCTAssertEqual(parsed.thinkingBlocks, ["loud"])
        XCTAssertEqual(parsed.answer, "quiet")
    }

    func testVisibleContentStripsThinking() {
        XCTAssertEqual(
            ThinkingContentParser.visibleContent(of: "<thinking>secret reasoning</thinking>Shown."),
            "Shown."
        )
    }

    func testContainsThinkingTags() {
        XCTAssertTrue(ThinkingContentParser.containsThinkingTags("a <thinking> b"))
        XCTAssertFalse(ThinkingContentParser.containsThinkingTags("plain text"))
    }

    /// Reasoning templates that pre-fill the opening tag emit output that
    /// starts mid-thought: the first tag present is the closing one.
    /// Everything before it is reasoning, not answer.
    func testClosingTagOnlyIsLeadingThinking() {
        let parsed = ThinkingContentParser.parse("Let me reason first.</think>The answer is 42.")
        XCTAssertEqual(parsed.thinkingBlocks, ["Let me reason first."])
        XCTAssertEqual(parsed.answer, "The answer is 42.")
    }

    func testClosingThinkingTagOnlyVariant() {
        let parsed = ThinkingContentParser.parse("Reasoning here.</thinking>Answer here.")
        XCTAssertEqual(parsed.thinkingBlocks, ["Reasoning here."])
        XCTAssertEqual(parsed.answer, "Answer here.")
    }

    /// Harmony-format models delimit reasoning with channel markers.
    func testHarmonyAnalysisChannelIsThinking() {
        let raw = "<|channel|>analysis<|channel|>Working it out.<|channel|>final<|channel|>Done.<|end|>"
        let parsed = ThinkingContentParser.parse(raw)
        XCTAssertEqual(parsed.thinkingBlocks, ["Working it out."])
        XCTAssertEqual(parsed.answer, "Done.")
    }
}
