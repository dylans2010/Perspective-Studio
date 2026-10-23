import Foundation

/// Lists running applications from NSWorkspace.
public struct ComputerListApplicationsTool: AssistTool {
    public let id = "computer_list_applications"
    public let name = "List Applications"
    public let description = "Lists the applications currently running on this Mac (regular and accessory activation policies), with name, bundle identifier, pid, and which one is frontmost. Use the returned pid/bundleId to target accessibility, window and verification tools."

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
        let apps = await ComputerUseApplications.listRunning()
        let output = apps.isEmpty
            ? "No running applications were reported by NSWorkspace."
            : apps.map { $0.summary }.joined(separator: "\n")
        let json = ComputerUseArguments.jsonString(apps.map { $0.jsonObject })
        return ComputerUseService.success("Running applications (\(apps.count)):\n\(output)", data: ["count": String(apps.count), "applications": json])
        #endif
    }
}
