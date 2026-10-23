import Foundation

/// Waits for a bounded duration, or until a verifiable condition
/// holds (polled), with a hard timeout and cancellation support.
public struct ComputerWaitTool: AssistTool {
    public let id = "computer_wait"
    public let name = "Wait"
    public let description = "Waits either for a fixed number of seconds (argument seconds, max 30) or until a computer_verify_state condition becomes true (arguments condition + its parameters, plus timeoutSeconds, max 30, and pollIntervalSeconds, default 0.5). Condition waits poll the real state — prefer them over fixed sleeps whenever an observable condition exists (app became frontmost, window appeared, text is on screen). A condition wait that times out returns success=false with the last observed evidence, not a hang, and cancellation stops the wait immediately."

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: description,
            properties: [
                "seconds": JSONSchema(type: "number", description: "Fixed wait duration in seconds (max 30). Use only when no observable condition applies."),
                "condition": JSONSchema(type: "string", description: "Condition to wait for — one of: app_frontmost, app_running, window_exists, element_exists, element_value_contains, text_on_screen. Supply that condition's parameters as additional arguments (bundleId/name/pid, titleContains, role/title/label/identifier/value, expectedValue, text)."),
                "timeoutSeconds": JSONSchema(type: "number", description: "For condition waits: give up after this many seconds (default 10, max 30)."),
                "pollIntervalSeconds": JSONSchema(type: "number", description: "For condition waits: seconds between state checks (default 0.5, min 0.1).")
            ],
            required: []
        )
    }

    public init() {}

    public var capability: ToolCapability { .computerUse }
    public var riskLevel: ToolRiskLevel { .safeRead }
    public var requiredPermission: ToolPermissionRequirement { .none }

    public func execute(input: [String: Any], context: AssistContext) async throws -> AssistToolResult {
        if let gate = ComputerUseService.gate(toolID: id, input: input, permissions: []) {
            return gate
        }
        #if !os(macOS)
        return ComputerUseError.platformUnavailable.result
        #else
        if let condition = ComputerUseArguments.string(input, "condition") {
            let timeout = min(max(ComputerUseArguments.double(input, "timeoutSeconds") ?? 10, 0.5), ComputerUseSafety.Limits.maxWaitSeconds)
            let interval = min(max(ComputerUseArguments.double(input, "pollIntervalSeconds") ?? 0.5, 0.1), 5)
            let deadline = Date.now.addingTimeInterval(timeout)
            var lastEvidence = "condition was never evaluated"
            var attempts = 0
            while true {
                if Task.isCancelled { return ComputerUseError.cancelled.result }
                attempts += 1
                do {
                    let outcome = try await ComputerUseVerification.evaluate(input: input.merging(["condition": condition]) { _, new in new })
                    lastEvidence = outcome.evidence
                    if outcome.met {
                        return ComputerUseService.success(
                            "Condition \"\(condition)\" became true after \(attempts) check(s). Evidence: \(outcome.evidence)",
                            data: ["condition": condition, "met": "true", "attempts": String(attempts), "evidence": outcome.evidence]
                        )
                    }
                } catch let error as ComputerUseError {
                    // A malformed condition should fail fast, not poll.
                    switch error {
                    case .invalidArgument, .unsupported:
                        return error.result
                    default:
                        lastEvidence = error.message
                    }
                } catch {
                    lastEvidence = error.localizedDescription
                }
                if Date.now >= deadline {
                    return AssistToolResult.failure(
                        "Timed out after \(ComputerUseRect.format(timeout))s waiting for condition \"\(condition)\" (\(attempts) check(s)). Last evidence: \(lastEvidence)",
                        code: .timeout,
                        diagnostics: [lastEvidence],
                        suggestedNextActions: ["Re-observe the desktop to decide whether the condition can still occur, or whether a different action is needed."]
                    )
                }
                try? await Task.sleep(for: .seconds(interval))
            }
        }

        guard let seconds = ComputerUseArguments.double(input, "seconds") else {
            return ComputerUseError.invalidArgument("Provide either seconds (fixed wait) or condition + its parameters (condition wait).").result
        }
        guard seconds > 0, seconds <= ComputerUseSafety.Limits.maxWaitSeconds else {
            return ComputerUseError.invalidArgument("seconds must be > 0 and <= \(Int(ComputerUseSafety.Limits.maxWaitSeconds)) (got \(seconds)). For longer waits, chain computer_wait calls around observations.").result
        }
        do {
            try await Task.sleep(for: .seconds(seconds))
        } catch {
            return ComputerUseError.cancelled.result
        }
        return ComputerUseService.success("Waited \(ComputerUseRect.format(seconds)) second(s). Re-observe before acting — do not assume what changed during the wait.", data: ["seconds": String(seconds)])
        #endif
    }
}
