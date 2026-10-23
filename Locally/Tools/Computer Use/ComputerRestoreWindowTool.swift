import Foundation

/// Restores (un-minimizes) one identified window.
public struct ComputerRestoreWindowTool: AssistTool {
    public let id = "computer_restore_window"
    public let name = "Restore Window"
    public let description = "Restores a minimized window, identified by app (pid/bundleId/appName, default frontmost) plus windowIndex or titleContains, by clearing its accessibility minimized attribute. The result reports the window as re-read afterwards."

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: description,
            properties: [
                "pid": JSONSchema(type: "integer", description: "Owning application process id."),
                "bundleId": JSONSchema(type: "string", description: "Owning application bundle identifier."),
                "appName": JSONSchema(type: "string", description: "Owning application name."),
                "windowIndex": JSONSchema(type: "integer", description: "Window index within its app."),
                "titleContains": JSONSchema(type: "string", description: "Select the window whose title contains this text.")
            ],
            required: []
        )
    }

    public init() {}

    public var capability: ToolCapability { .computerUse }
    public var riskLevel: ToolRiskLevel { .execution }
    public var requiredPermission: ToolPermissionRequirement { .accessibility }

    public func execute(input: [String: Any], context: AssistContext) async throws -> AssistToolResult {
        if let gate = ComputerUseService.gate(toolID: id, input: input, permissions: [.accessibility]) {
            return gate
        }
        #if !os(macOS)
        return ComputerUseError.platformUnavailable.result
        #else
        do {
            let pid = try await ComputerUseVerification.resolvedPID(input)
            let updated = try ComputerUseWindows.setMinimized(
                false,
                pid: pid,
                index: ComputerUseArguments.int(input, "windowIndex", "index"),
                titleContains: ComputerUseArguments.string(input, "titleContains")
            )
            return ComputerUseService.success(
                "Window after restore request: \(updated.summary). Minimized state observed: \(updated.isMinimized).",
                data: ["window": ComputerUseArguments.jsonString(updated.jsonObject), "isMinimized": updated.isMinimized ? "true" : "false"]
            )
        } catch {
            return .computerUseFailure(error)
        }
        #endif
    }
}
