import Foundation

/// Launches an installed application by bundle id or name.
public struct ComputerOpenApplicationTool: AssistTool {
    public let id = "computer_open_application"
    public let name = "Open Application"
    public let description = "Launches an installed application, identified by bundleId or by its exact installed name (e.g. \"TextEdit\", \"Safari\"), using NSWorkspace. If the app is already running it is activated instead. Only applications that are actually installed can be opened — an unknown bundle id/name returns a not-found error, never a fake success. The result reports the launched app's pid and whether it was already running."

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: description,
            properties: [
                "bundleId": JSONSchema(type: "string", description: "Bundle identifier of the app to open, e.g. \"com.apple.TextEdit\"."),
                "name": JSONSchema(type: "string", description: "Installed application name (used when bundleId is not given).")
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
        let bundleId = ComputerUseArguments.string(input, "bundleId", "bundle_id", "bundleIdentifier")
        let name = ComputerUseArguments.string(input, "name", "appName")
        guard bundleId != nil || name != nil else {
            return ComputerUseError.invalidArgument("Provide bundleId or name for the application to open.").result
        }
        do {
            let outcome = try await ComputerUseApplications.open(bundleIdentifier: bundleId, name: name)
            return ComputerUseService.success(
                "\(outcome.wasAlreadyRunning ? "Activated already-running" : "Launched") application: \(outcome.info.summary). Observe its windows/elements before acting further — launch completion does not mean the app has finished loading its UI.",
                data: ["pid": String(outcome.info.pid), "name": outcome.info.name, "wasAlreadyRunning": outcome.wasAlreadyRunning ? "true" : "false"]
            )
        } catch {
            return .computerUseFailure(error)
        }
    }
}
