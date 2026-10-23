import Foundation

/// Closes an application gracefully — never by force.
public struct ComputerCloseApplicationTool: AssistTool {
    public let id = "computer_close_application"
    public let name = "Close Application"
    public let description = "Asks a running application (by pid, bundleId or name) to terminate gracefully. Computer Use NEVER force-terminates: if the app is still running after a grace period, it is almost certainly showing an unsaved-work or confirmation dialog — the result reports that, and the dialog is the user's decision. Only close an app when the user's task actually asks for it. Locally refuses to close itself."

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
    public var riskLevel: ToolRiskLevel { .potentiallyDestructive }
    public var isDestructive: Bool { true }
    public var requiredPermission: ToolPermissionRequirement { .none }

    public func execute(input: [String: Any], context: AssistContext) async throws -> AssistToolResult {
        if let gate = ComputerUseService.gate(toolID: id, input: input, permissions: []) {
            return gate
        }
        let bundleId = ComputerUseArguments.string(input, "bundleId", "bundle_id")
        let name = ComputerUseArguments.string(input, "name", "appName")
        let pid = ComputerUseArguments.int(input, "pid").map { Int32($0) }
        guard bundleId != nil || name != nil || pid != nil else {
            return ComputerUseError.invalidArgument("Provide one of pid, bundleId or name to identify the application to close.").result
        }
        #if !os(macOS)
        return ComputerUseError.platformUnavailable.result
        #else
        // Distinguish "not running" (a no-op the model should know
        // about) from a close that was actually dispatched.
        if (try? await ComputerUseApplications.resolveRunning(bundleIdentifier: bundleId, name: name, pid: pid)) == nil {
            return ComputerUseError.notFound("running application matching the given identifier — nothing was closed.").result
        }
        let outcome = await ComputerUseApplications.close(bundleIdentifier: bundleId, name: name, pid: pid)
        if outcome.terminated {
            return ComputerUseService.success("Application terminated: \(outcome.info.summary).", data: ["pid": String(outcome.info.pid), "terminated": "true"])
        }
        return ComputerUseService.success(
            "Termination was requested for \(outcome.info.summary), but the application is STILL RUNNING. It was not force-terminated. It is likely showing an unsaved-work or confirmation dialog, or it refused to quit — inspect its window/dialog (computer_list_windows, screenshot) and involve the user before deciding anything else.",
            data: ["pid": String(outcome.info.pid), "terminated": "false"]
        )
        #endif
    }
}
