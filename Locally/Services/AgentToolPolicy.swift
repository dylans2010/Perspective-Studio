import Foundation

/// The tool-use policy for Agent-mode runs — in particular the Project
/// mandate: **when a Project is active, the agent must actually use its
/// tools.** A model that answers a project task straight from its
/// weights — never listing the folder, never reading a file — is not
/// working in the project, it is guessing about it, so the loop does
/// not accept a final answer until at least one tool has run.
///
/// This type is the pure, testable core of that rule. The harness
/// (`AntigravityAgentHarness`) and the Apple-model runner
/// (`FoundationModelAgentRunner`) both consult it; the prompt text it
/// provides is what the model sees when the loop pushes back.
public enum AgentToolPolicy {

    /// How many times the loop will send the model back to use a tool
    /// before accepting its answer anyway (a model stuck refusing tools
    /// must not loop forever — after this, the run completes and the
    /// trace shows the rejections).
    public nonisolated static let maxProjectToolRejections = 3

    /// True when a would-be final answer must be rejected and the model
    /// sent back to call a tool first.
    ///
    /// The mandate applies to TASK turns only: a greeting or a direct
    /// question asked while a project happens to be selected is still
    /// conversation, and forcing a tool call for it (the old behavior —
    /// a project greeting triggered an exploration run, and the loop's
    /// rejection machinery leaked its "[Draft answer withheld]" marker
    /// into the model-visible history) is exactly the failure this
    /// policy now excludes via `intent`.
    public nonisolated static func mustRejectFinalAnswer(
        toolCallsExecuted: Int,
        projectActive: Bool,
        requireToolUse: Bool,
        rejectionsUsed: Int,
        intent: ConversationIntent = .task
    ) -> Bool {
        intent == .task
            && projectActive
            && requireToolUse
            && toolCallsExecuted == 0
            && rejectionsUsed < maxProjectToolRejections
    }

    /// The mandate stated in the system prompt for a project run.
    public nonisolated static func projectMandate(projectName: String) -> String {
        """
        ## Project Tool Mandate — \(projectName) (non-negotiable)
        You are working inside the project "\(projectName)". For this run you MUST use your tools — answering from memory or general knowledge alone is not allowed:
        - Your FIRST action must be a tool call that explores the project (its structure, the relevant files) before you reason about specifics.
        - Ground every claim about the project in something a tool actually showed you during this run.
        - The runtime enforces this: a final answer given before any tool has run will be rejected and you will be asked again.
        """
    }

    /// The user-turn text fed back when the loop rejects a tool-less
    /// final answer in a project run.
    public nonisolated static func rejectionPrompt(projectName: String) -> String {
        """
        You are working in the project "\(projectName)", and in a project you must ALWAYS use your tools before answering — that answer was not based on anything you inspected in this run, so it was not accepted.

        Call a tool NOW as your only output: start by exploring the project structure, then read the files relevant to the task. Only give a final answer after at least one tool result is in.
        """
    }
}
