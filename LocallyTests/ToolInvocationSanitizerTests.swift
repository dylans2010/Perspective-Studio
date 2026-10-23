import XCTest
@testable import Locally

/// The sanitizer is the last line of defense between a model's raw tool
/// protocol and the user's screen. These tests pin the exact leak from the
/// 2026-10-23 screenshots (a bare invocation JSON rendered as the
/// assistant's message) plus the surrounding cases.
final class ToolInvocationSanitizerTests: XCTestCase {

    private let knownIDs: Set<String> = [
        "computer_get_permissions", "computer_screenshot", "file_append",
        "file_read", "calculator", "project_memory", "search_text"
    ]

    func testScreenshotLeakBareJSONPrefixIsStripped() {
        // Verbatim shape of the leaked message: invocation JSON immediately
        // followed by the model's prose about the result.
        let leaked = "{\"tool\": \"computer_get_permissions\", \"arguments\": {\"action\": \"check\"}}Based on the output, both permissions are granted."
        let cleaned = ToolInvocationSanitizer.displayText(for: leaked, knownToolIDs: knownIDs)
        XCTAssertEqual(cleaned, "Based on the output, both permissions are granted.")
        XCTAssertFalse(cleaned.contains("computer_get_permissions"))
        XCTAssertFalse(cleaned.contains("\"tool\""))
    }

    func testToolCallLineIsStrippedAndProseKept() {
        let text = "Let me check that.\nTOOL_CALL {\"tool\": \"file_read\", \"arguments\": {\"path\": \"a.txt\"}}\nThe file says hello."
        let cleaned = ToolInvocationSanitizer.displayText(for: text, knownToolIDs: knownIDs)
        XCTAssertFalse(cleaned.contains("TOOL_CALL"))
        XCTAssertFalse(cleaned.contains("file_read"))
        XCTAssertTrue(cleaned.contains("The file says hello."))
    }

    func testPartialStreamingInvocationIsHidden() {
        // Mid-stream: the JSON has not closed yet. Nothing from the '{' of
        // the tool object onward may be shown.
        let partial = "Working on it. {\"tool\": \"computer_screenshot\", \"arguments\": {\"displ"
        let cleaned = ToolInvocationSanitizer.displayText(for: partial, knownToolIDs: knownIDs)
        XCTAssertEqual(cleaned, "Working on it.")
    }

    func testPartialToolCallMarkerIsHidden() {
        let partial = "One moment. TOOL_CALL {\"tool\": \"search_text\", \"argu"
        let cleaned = ToolInvocationSanitizer.displayText(for: partial, knownToolIDs: knownIDs)
        XCTAssertEqual(cleaned, "One moment.")
    }

    func testFencedJSONInvocationIsStripped() {
        let text = "Here is what I found.\n```json\n{\"tool\": \"calculator\", \"arguments\": {\"expression\": \"2+2\"}}\n```\nThe result is 4."
        let cleaned = ToolInvocationSanitizer.displayText(for: text, knownToolIDs: knownIDs)
        XCTAssertFalse(cleaned.contains("calculator"))
        XCTAssertTrue(cleaned.contains("The result is 4."))
    }

    func testUnrelatedJSONExampleSurvives() {
        // A JSON example about some other "tool" is user content, not an
        // invocation of one of Locally's tools.
        let text = "For example: {\"tool\": \"hammer\", \"arguments\": {\"nails\": 3}} is a fine inventory record."
        let cleaned = ToolInvocationSanitizer.displayText(for: text, knownToolIDs: knownIDs)
        XCTAssertEqual(cleaned, text)
    }

    func testOrdinaryCodeBlockSurvives() {
        let text = "Use this:\n```swift\nlet x = 1\n```\nDone."
        XCTAssertEqual(ToolInvocationSanitizer.displayText(for: text, knownToolIDs: knownIDs), text)
    }

    func testXMLToolCallWrapperIsStripped() {
        let text = "<tool_call>{\"tool\": \"file_read\", \"arguments\": {}}</tool_call>The answer is ready."
        let cleaned = ToolInvocationSanitizer.displayText(for: text, knownToolIDs: knownIDs)
        XCTAssertEqual(cleaned, "The answer is ready.")
    }

    func testRawIDLabelPatternIsRedactedKeepingHumanLabel() {
        let cleaned = ToolInvocationSanitizer.displayText(
            for: "file_append: Append to File — done. Next I read it back.",
            knownToolIDs: knownIDs
        )
        XCTAssertFalse(cleaned.contains("file_append"))
        XCTAssertTrue(cleaned.hasPrefix("Append to File"))
    }

    func testBacktickedAndBareIDsBecomeHumanNames() {
        let cleaned = ToolInvocationSanitizer.displayText(
            for: "I used `file_read` and then file_append to finish.",
            knownToolIDs: knownIDs
        )
        XCTAssertFalse(cleaned.contains("file_read"))
        XCTAssertFalse(cleaned.contains("file_append"))
        XCTAssertTrue(cleaned.contains("Reading File"))
    }

    func testContainsInvocation() {
        XCTAssertTrue(ToolInvocationSanitizer.containsInvocation("TOOL_CALL {\"tool\": \"file_read\"}", knownToolIDs: knownIDs))
        XCTAssertTrue(ToolInvocationSanitizer.containsInvocation("{\"tool\": \"file_read\", \"arguments\": {}}", knownToolIDs: knownIDs))
        XCTAssertFalse(ToolInvocationSanitizer.containsInvocation("Just a normal answer.", knownToolIDs: knownIDs))
    }

    func testEmptyAndPlainTextPassThrough() {
        XCTAssertEqual(ToolInvocationSanitizer.displayText(for: "", knownToolIDs: knownIDs), "")
        XCTAssertEqual(ToolInvocationSanitizer.displayText(for: "Hello there.", knownToolIDs: knownIDs), "Hello there.")
    }
}
