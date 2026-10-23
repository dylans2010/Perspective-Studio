import Foundation

/// Activates a running application and reports whether it verifiably
/// became frontmost.
public struct ComputerFocusApplicationTool: AssistTool {
    public let id = "computer_focus_application"
    public let name = "Focus Application"
    public let description = "Activates a running application (by pid, bundleId or name) so it becomes frontmost, then re-checks the frontmost application and reports whether activation is verified. Activation can be refused by macOS or stolen by another app — the result says what was actually observed."

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: description,
            properties: [
                "pid": JSONSchema(type: "integer", description: "Process id of the running app."),
                "bundleId": JSONSchema(type: "string", description: "Bundle identifier of the running app."),
                "name": JSONSchema(type: "string", description: "Name of the running app (exact, case-insensitive).")
            ],
            required: []
        )
    }

    public init() {}

    public var capability: ToolCapability { .computerUse }
    public var riskLevel: ToolRiskLevel { .execution }
    public var requiredPermission: ToolPermissionRequirement { .none }

    public func execute(input: [String: Any], context: AssistContext) async throws -> AssistToolResult {
        if let gate = ComputerUseService.gate(toolID: id, input: input, permissions: []) {
            return gate
        }
        do {
            let outcome = try await ComputerUseApplications.activate(
                bundleIdentifier: ComputerUseArguments.string(input, "bundleId", "bundle_id"),
                name: ComputerUseArguments.string(input, "name", "appName"),
                pid: ComputerUseArguments.int(input, "pid").map { Int32($0) }
            )
            return ComputerUseService.success(
                outcome.verifiedFrontmost
                    ? "Activated and verified frontmost: \(outcome.info.summary)."
                    : "Activation was requested for \(outcome.info.summary), but the frontmost application afterwards was different — activation is NOT verified. Another app may have taken focus; re-check with computer_get_focused_application.",
                data: ["pid": String(outcome.info.pid), "verifiedFrontmost": outcome.verifiedFrontmost ? "true" : "false"]
            )
        } catch {
            return .computerUseFailure(error)
        }
    }
}
