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
}
