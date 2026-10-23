import Foundation

/// Structured error for every Computer Use failure.
///
/// Tools never return a bare string for a failure and never report
/// success for an unsupported or unverified operation — they return
/// `AssistToolResult.failure` built from one of these cases, with the
/// matching `AssistToolErrorCode` and a recovery hint the model can act
/// on (grant a permission, re-observe, narrow the query, …).
public enum ComputerUseError: Error, Sendable {
    /// A required macOS permission (Accessibility / Screen Recording)
    /// is not granted. `guidance` explains how the user grants it.
    case permissionDenied(permission: String, guidance: String)
    /// A tool argument is missing, mistyped or out of range.
    case invalidArgument(String)
    /// The requested app, window or element does not exist (any more).
    case notFound(String)
    /// A query matched more than one candidate; acting would be a guess.
    case ambiguous(String, candidates: [String])
    /// The target exists but does not support the requested operation.
    case unsupported(String)
    /// Coordinates fall outside every display, or a target captured
    /// earlier can no longer be validated against the current screen.
    case staleOrInvalidTarget(String)
    /// An underlying macOS API failed.
    case executionFailed(String)
    /// The operation did not finish inside its bounded timeout.
    case timedOut(String)
    /// The task was cancelled before / during the operation.
    case cancelled
    /// Computer Use requires macOS; this build is running elsewhere.
    case platformUnavailable

    public var message: String {
        switch self {
        case .permissionDenied(let permission, let guidance):
            return "\(permission) permission is not granted to Locally. \(guidance)"
        case .invalidArgument(let detail):
            return "Invalid argument: \(detail)"
        case .notFound(let detail):
            return "Not found: \(detail)"
        case .ambiguous(let detail, let candidates):
            let list = candidates.prefix(8).joined(separator: "; ")
            return "Ambiguous target: \(detail). Candidates: \(list). Re-run with a more specific query."
        case .unsupported(let detail):
            return "Unsupported: \(detail)"
        case .staleOrInvalidTarget(let detail):
            return "Target is stale or outside the screen: \(detail). Take a fresh observation (computer_screenshot / computer_get_accessibility_tree) and retry with current coordinates."
        case .executionFailed(let detail):
            return "Execution failed: \(detail)"
        case .timedOut(let detail):
            return "Timed out: \(detail)"
        case .cancelled:
            return "The Computer Use operation was cancelled. No further actions were dispatched."
        case .platformUnavailable:
            return "Computer Use is only available on macOS."
        }
    }

    public var code: AssistToolErrorCode {
        switch self {
        case .permissionDenied: return .permissionDenied
        case .invalidArgument: return .invalidInput
        case .notFound, .ambiguous: return .notFound
        case .unsupported, .platformUnavailable: return .unsupportedOperation
        case .staleOrInvalidTarget: return .invalidInput
        case .executionFailed: return .executionFailed
        case .timedOut: return .timeout
        case .cancelled: return .cancelled
        }
    }

    public var recoveryHint: String {
        switch self {
        case .permissionDenied:
            return "Ask the user to grant the permission (computer_get_permissions can open the right System Settings pane), then retry."
        case .invalidArgument:
            return "Fix the argument against the tool schema and retry."
        case .notFound:
            return "Re-observe the desktop (computer_list_applications / computer_list_windows / computer_get_accessibility_tree) and retry with an identifier that exists now."
        case .ambiguous:
            return "Narrow the query (role + title + identifier) or use the candidate's exact coordinates from the result."
        case .unsupported:
            return "Use a different approach: prefer an accessibility action, or a coordinate click grounded in a fresh screenshot."
        case .staleOrInvalidTarget:
            return "Refresh the observation before acting; do not reuse coordinates from an older screenshot after the layout may have changed."
        case .executionFailed:
            return "Inspect the detail, re-observe the current state, and retry only if the action has not already taken effect."
        case .timedOut:
            return "Re-observe the current state before deciding whether to retry; the action may have partially completed."
        case .cancelled:
            return "Stop the workflow and report what was already executed."
        case .platformUnavailable:
            return "Run Locally on macOS to use Computer Use."
        }
    }

    /// The `AssistToolResult` for this error.
    public var result: AssistToolResult {
        .failure(message, code: code, diagnostics: [message], suggestedNextActions: [recoveryHint])
    }
}

extension AssistToolResult {
    /// Convenience: build a failure result from a `ComputerUseError`.
    static func computerUseFailure(_ error: ComputerUseError) -> AssistToolResult {
        error.result
    }

    /// Convenience: build a failure result from any error, preserving
    /// `ComputerUseError` structure when present.
    static func computerUseFailure(_ error: Error) -> AssistToolResult {
        if let cu = error as? ComputerUseError { return cu.result }
        if error is CancellationError { return ComputerUseError.cancelled.result }
        return .failure(error.localizedDescription, code: .executionFailed)
    }
}
