import Foundation

/// Moves one identified window to a global-point position.
public struct ComputerMoveWindowTool: AssistTool {
    public let id = "computer_move_window"
    public let name = "Move Window"
    public let description = "Moves a window's top-left corner to (x, y) in global points, identified by app (pid/bundleId/appName, default frontmost) plus windowIndex or titleContains. The result reports the window's bounds as re-read after the move. Some applications refuse external window moves — that failure is reported with the real accessibility error."

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
                "x": JSONSchema(type: "number", description: "New left edge, global points."),
                "y": JSONSchema(type: "number", description: "New top edge, global points.")
            ],
            required: ["x", "y"]
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
        guard let point = ComputerUseArguments.point(input) else {
            return ComputerUseError.invalidArgument("computer_move_window requires numeric x and y arguments.").result
        }
        do {
            let pid = try await ComputerUseVerification.resolvedPID(input)
            let updated = try ComputerUseWindows.move(
                pid: pid,
                index: ComputerUseArguments.int(input, "windowIndex", "index"),
                titleContains: ComputerUseArguments.string(input, "titleContains"),
                toX: point.x, y: point.y
            )
            return ComputerUseService.success("Window after move: \(updated.summary).", data: ["window": ComputerUseArguments.jsonString(updated.jsonObject)])
        } catch {
            return .computerUseFailure(error)
        }
        #endif
    }
}
