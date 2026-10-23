import XCTest
@testable import Locally

/// The Project Tool Mandate: with a project active, a final answer is
/// only acceptable after at least one tool has actually run.
@MainActor
final class AgentToolPolicyTests: XCTestCase {

    func testToolLessAnswerInProjectIsRejected() {
        XCTAssertTrue(AgentToolPolicy.mustRejectFinalAnswer(
            toolCallsExecuted: 0, projectActive: true, requireToolUse: true, rejectionsUsed: 0
        ))
    }

    func testAnswerAfterToolUseIsAccepted() {
        XCTAssertFalse(AgentToolPolicy.mustRejectFinalAnswer(
            toolCallsExecuted: 1, projectActive: true, requireToolUse: true, rejectionsUsed: 0
        ))
    }

    func testNoProjectMeansNoMandate() {
        XCTAssertFalse(AgentToolPolicy.mustRejectFinalAnswer(
            toolCallsExecuted: 0, projectActive: false, requireToolUse: true, rejectionsUsed: 0
        ))
    }

    func testMandateCanBeSwitchedOffPerProject() {
        XCTAssertFalse(AgentToolPolicy.mustRejectFinalAnswer(
            toolCallsExecuted: 0, projectActive: true, requireToolUse: false, rejectionsUsed: 0
        ))
    }

    func testRejectionsAreBounded() {
        XCTAssertFalse(AgentToolPolicy.mustRejectFinalAnswer(
            toolCallsExecuted: 0, projectActive: true, requireToolUse: true,
            rejectionsUsed: AgentToolPolicy.maxProjectToolRejections
        ))
    }

    func testMandateAndRejectionPromptsNameTheProject() {
        XCTAssertTrue(AgentToolPolicy.projectMandate(projectName: "Demo").contains("Demo"))
        XCTAssertTrue(AgentToolPolicy.rejectionPrompt(projectName: "Demo").contains("Demo"))
        XCTAssertTrue(AgentToolPolicy.rejectionPrompt(projectName: "Demo").contains("ALWAYS"))
    }

    /// The loop engine splits reasoning out of agent turns so it renders
    /// as thinking, never as part of the final answer.
    func testLoopEngineSplitsThinkingFromAnswer() {
        let split = AntigravityLoopEngine.splitThinking(
            from: "<thinking>checking the files</thinking>The project has three targets."
        )
        XCTAssertEqual(split.thinking, "checking the files")
        XCTAssertEqual(split.answer, "The project has three targets.")
    }

    func testLoopEngineSplitWithoutThinking() {
        let split = AntigravityLoopEngine.splitThinking(from: "Plain answer.")
        XCTAssertNil(split.thinking)
        XCTAssertEqual(split.answer, "Plain answer.")
    }

    /// Thinking Mode's effective default is ON — the bug was inference
    /// reading `bool(forKey:)` (false for a never-written key) while the
    /// UI showed the switch on.
    func testThinkingSettingsDefaultIsEnabled() {
        let key = ThinkingSettings.enabledKey
        let original = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
        }
        XCTAssertTrue(ThinkingSettings.isEnabled)
        XCTAssertEqual(ThinkingSettings.budget.isEmpty, false)
    }
}
