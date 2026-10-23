import XCTest
@testable import Locally

/// The MLX agent loop's history bounding: the assembled prompt keeps the
/// first turn (the objective) and the current turn in full, excerpts
/// older turns, and never exceeds the total character budget — so a
/// long run stops re-prefilling its entire transcript on every turn.
@MainActor
final class AntigravityAgentHarnessTests: XCTestCase {

    private typealias Turn = AntigravityAgentHarness.Turn

    func testShortHistoryAssemblesExactlyAsBefore() {
        let assembled = AntigravityAgentHarness.assemblePrompt(turns: [
            Turn(role: "user", content: "hi"),
            Turn(role: "assistant", content: "hello")
        ])
        XCTAssertEqual(assembled, "User: hi\n\nAssistant: hello\n\nAssistant:")
    }

    func testFirstAndCurrentTurnsAreNeverTruncated() {
        let longOutput = String(repeating: "observation line ", count: 200) + "TAIL-MARKER"
        let assembled = AntigravityAgentHarness.assemblePrompt(turns: [
            Turn(role: "user", content: "OBJECTIVE-MARKER explore the project"),
            Turn(role: "user", content: longOutput),
            Turn(role: "user", content: "CURRENT-QUESTION-MARKER what did you find?")
        ])
        XCTAssertTrue(assembled.contains("OBJECTIVE-MARKER explore the project"))
        XCTAssertTrue(assembled.contains("CURRENT-QUESTION-MARKER what did you find?"))
        // The older middle turn is excerpted, marker and all.
        XCTAssertTrue(assembled.contains(AntigravityAgentHarness.historyTruncationMarker))
        XCTAssertFalse(assembled.contains("TAIL-MARKER"))
    }

    func testAssembledPromptRespectsTheTotalCharacterBudget() {
        var turns: [Turn] = [Turn(role: "user", content: "OBJECTIVE-MARKER")]
        for index in 0..<80 {
            turns.append(Turn(role: "user", content: "turn \(index) " + String(repeating: "x", count: 5_000)))
        }
        turns.append(Turn(role: "user", content: "CURRENT-MARKER final question"))
        let assembled = AntigravityAgentHarness.assemblePrompt(turns: turns)
        XCTAssertLessThanOrEqual(assembled.count, AntigravityAgentHarness.maxAssembledPromptCharacters)
        XCTAssertTrue(assembled.contains("OBJECTIVE-MARKER"))
        XCTAssertTrue(assembled.contains("CURRENT-MARKER final question"))
    }
}
