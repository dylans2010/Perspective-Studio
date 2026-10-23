import Foundation

/// The Computer Use service: lifecycle, gating and execution helpers
/// shared by every Computer Use tool.
///
/// Responsibilities (and only these — observation lives in
/// `ComputerUseScreen` / `ComputerUseAccessibility` / `ComputerUseOCR`,
/// actions in `ComputerUseMouse` / `ComputerUseKeyboard` /
/// `ComputerUseApplications` / `ComputerUseWindows`):
///
/// - Permission gating: `gate(_:)` is the single entry every tool
///   calls before touching a macOS API that needs a permission.
/// - Safety gating: `safetyCheck(toolID:input:)`.
/// - Bounded execution: `withTimeout` races work against a deadline
///   and honours task cancellation, so no tool call can hang a run.
/// - Result shaping: success results distinguish *executed* from
///   *verified* — a tool only claims verification when it actually
///   re-observed the state (see `ComputerUseVerification`).
public enum ComputerUseService {

    /// Returns the failure result a tool must return before doing any
    /// work, or nil when it may proceed. Checks, in order: platform,
    /// cancellation, safety policy, then each required permission.
    public static func gate(
        toolID: String,
        input: [String: Any],
        permissions: [ComputerUsePermissionKind]
    ) -> AssistToolResult? {
        #if !os(macOS)
        return ComputerUseError.platformUnavailable.result
        #else
        if Task.isCancelled { return ComputerUseError.cancelled.result }
        if let error = ComputerUseSafety.validate(toolID: toolID, input: input) {
            return error.result
        }
        for kind in permissions {
            if let failure = ComputerUsePermissions.failureIfMissing(kind) {
                return failure
            }
        }
        return nil
        #endif
    }

    /// Runs `operation` with a bounded timeout (default: the Computer
    /// Use per-tool limit). Throws `ComputerUseError.timedOut` if the
    /// deadline passes, `ComputerUseError.cancelled` on cancellation.
    public static func withTimeout<T: Sendable>(
        seconds: Double = ComputerUseSafety.Limits.defaultToolTimeoutSeconds,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw ComputerUseError.timedOut("operation exceeded \(Int(seconds))s")
            }
            guard let result = try await group.next() else {
                throw ComputerUseError.executionFailed("timeout race produced no result")
            }
            group.cancelAll()
            return result
        }
    }

    /// Throws `ComputerUseError.cancelled` when the current task has
    /// been cancelled. Long-running service methods call this between
    /// steps so cancellation stops further actions from dispatching.
    public static func checkCancellation() throws {
        if Task.isCancelled { throw ComputerUseError.cancelled }
    }

    /// Builds a success result whose output text states what was
    /// actually done, with structured `data` for the model to chain on.
    public static func success(
        _ output: String,
        data: [String: String] = [:],
        suggestedNextActions: [String] = []
    ) -> AssistToolResult {
        .success(output, data: data.isEmpty ? nil : data, suggestedNextActions: suggestedNextActions)
    }
}
