import Foundation

/// Lists windows via the Accessibility API.
public struct ComputerListWindowsTool: AssistTool {
    public let id = "computer_list_windows"
    public let name = "List Windows"
    public let description = "Lists windows with title, owning application, bounds in global points, minimized/main state, CG window id when matchable, and indexInApp — the index used to address the same window in computer_focus_window / computer_move_window / computer_resize_window / computer_minimize_window / computer_restore_window. With pid/bundleId/appName it lists one app's windows; without, it lists windows across running apps (bounded to the first 12 apps)."

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: description,
            properties: [
                "pid": JSONSchema(type: "integer", description: "Only this application's windows."),
                "bundleId": JSONSchema(type: "string", description: "Only this application's windows (by bundle id)."),
                "appName": JSONSchema(type: "string", description: "Only this application's windows (by name).")
            ],
            required: []
        )
    }

    public init() {}

    public var capability: ToolCapability { .computerUse }
    public var riskLevel: ToolRiskLevel { .safeRead }
    public var requiredPermission: ToolPermissionRequirement { .accessibility }

    public func execute(input: [String: Any], context: AssistContext) async throws -> AssistToolResult {
        if let gate = ComputerUseService.gate(toolID: id, input: input, permissions: [.accessibility]) {
            return gate
        }
        #if !os(macOS)
        return ComputerUseError.platformUnavailable.result
        #else
        var pid: Int32?
        if ComputerUseArguments.int(input, "pid") != nil || ComputerUseArguments.string(input, "bundleId") != nil || ComputerUseArguments.string(input, "appName", "name") != nil {
            do {
                pid = try await ComputerUseVerification.resolvedPID(input)
            } catch {
                return .computerUseFailure(error)
            }
        }
        let windows = await ComputerUseWindows.list(pid: pid)
        if windows.isEmpty {
            return ComputerUseService.success("No windows were observed. The target app may have no open windows, or may not expose them to accessibility.", data: ["count": "0", "windows": "[]"])
        }
        let json = ComputerUseArguments.jsonString(windows.map { $0.jsonObject })
        return ComputerUseService.success(
            "Windows (\(windows.count)):\n" + windows.map { $0.summary }.joined(separator: "\n"),
            data: ["count": String(windows.count), "windows": json]
        )
        #endif
    }
}
