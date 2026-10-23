import Foundation

/// Resizes one identified window (points, minimum 50x50).
public struct ComputerResizeWindowTool: AssistTool {
    public let id = "computer_resize_window"
    public let name = "Resize Window"
    public let description = "Resizes a window to width x height in points, identified by app (pid/bundleId/appName, default frontmost) plus windowIndex or titleContains. The result reports the bounds as re-read after the resize — an app may clamp to its own minimum/maximum, so the re-read bounds are the truth, not the requested numbers."

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: description,
            properties: [
                "pid": JSONSchema(type: "integer", description: "Owning application process id."),
                "bundleId": JSONSchema(type: "string", description: "Owning application bundle identifier."),
                "appName": JSONSchema(type: "string", description: "Owning application name."),
                "windowIndex": JSONSchema(type: "integer", description: "Window index within its app."),
                "titleContains": JSONSchema(type: "string", description: "Select the window whose title contains this text."),
                "width": JSONSchema(type: "number", description: "New width in points (minimum 50)."),
                "height": JSONSchema(type: "number", description: "New height in points (minimum 50).")
            ],
            required: ["width", "height"]
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
        guard let width = ComputerUseArguments.double(input, "width"),
              let height = ComputerUseArguments.double(input, "height") else {
            return ComputerUseError.invalidArgument("computer_resize_window requires numeric width and height arguments.").result
        }
        do {
            let pid = try await ComputerUseVerification.resolvedPID(input)
            let updated = try ComputerUseWindows.resize(
                pid: pid,
                index: ComputerUseArguments.int(input, "windowIndex", "index"),
                titleContains: ComputerUseArguments.string(input, "titleContains"),
                width: width, height: height
            )
            return ComputerUseService.success("Window after resize: \(updated.summary).", data: ["window": ComputerUseArguments.jsonString(updated.jsonObject)])
        } catch {
            return .computerUseFailure(error)
        }
        #endif
    }
}
