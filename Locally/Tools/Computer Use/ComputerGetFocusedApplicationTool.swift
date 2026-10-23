import Foundation

/// Returns the frontmost application.
public struct ComputerGetFocusedApplicationTool: AssistTool {
    public let id = "computer_get_focused_application"
    public let name = "Get Focused Application"
    public let description = "Returns the frontmost (active) application: name, bundle identifier and pid, as reported by NSWorkspace. This is the app that will receive keyboard input."

    public var parametersSchema: JSONSchema {
        JSONSchema(type: "object", description: description, properties: [:], required: [])
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
        guard let front = await ComputerUseApplications.frontmost() else {
            return .failure("No frontmost application could be determined from NSWorkspace.", code: .executionFailed)
        }
        return ComputerUseService.success("Frontmost application: \(front.summary)", data: [
            "pid": String(front.pid), "name": front.name,
            "bundleIdentifier": front.bundleIdentifier ?? ""
        ])
        #endif
    }
}
