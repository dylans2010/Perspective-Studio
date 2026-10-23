import Foundation

/// Focuses (raises + activates) one identified window.
public struct ComputerFocusWindowTool: AssistTool {
    public let id = "computer_focus_window"
    public let name = "Focus Window"
    public let description = "Focuses one window: raises it via accessibility and activates its application, then re-reads the window and reports whether it is now the app's main window. Identify the app by pid/bundleId/appName (default: frontmost app) and the window by windowIndex or titleContains, as reported by computer_list_windows."

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: description,
            properties: [
                "pid": JSONSchema(type: "integer", description: "Owning application process id."),
                "bundleId": JSONSchema(type: "string", description: "Owning application bundle identifier."),
                "appName": JSONSchema(type: "string", description: "Owning application name."),
                "windowIndex": JSONSchema(type: "integer", description: "Index of the window within its app (from computer_list_windows)."),
                "titleContains": JSONSchema(type: "string", description: "Select the window whose title contains this text (must match exactly one).")
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
            let outcome = try await ComputerUseWindows.focus(
                pid: pid,
                index: ComputerUseArguments.int(input, "windowIndex", "index"),
                titleContains: ComputerUseArguments.string(input, "titleContains")
            )
            return ComputerUseService.success(
                outcome.verified
                    ? "Focused window (verified as the app's main window): \(outcome.info.summary)."
                    : "Focus was requested for \(outcome.info.summary), but it is not confirmed as the app's main window afterwards — another window/app may have taken focus.",
                data: ["window": ComputerUseArguments.jsonString(outcome.info.jsonObject), "verified": outcome.verified ? "true" : "false"]
            )
        } catch {
            return .computerUseFailure(error)
        }
        #endif
    }
}
