import Foundation

/// Moves the pointer to a global-point coordinate.
public struct ComputerMouseMoveTool: AssistTool {
    public let id = "computer_mouse_move"
    public let name = "Mouse Move"
    public let description = "Moves the mouse pointer to a coordinate in global points without clicking. Use it to reveal hover controls, tooltips or hover menus before a follow-up observation or click. Coordinates are validated against the current displays."

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: description,
            properties: [
                "x": JSONSchema(type: "number", description: "X coordinate in global points."),
                "y": JSONSchema(type: "number", description: "Y coordinate in global points.")
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
        guard let point = ComputerUseArguments.point(input) else {
            return ComputerUseError.invalidArgument("computer_mouse_move requires numeric x and y arguments.").result
        }
        do {
            try ComputerUseMouse.move(toX: point.x, y: point.y)
            return ComputerUseService.success("Moved the pointer to (\(ComputerUseRect.format(point.x)), \(ComputerUseRect.format(point.y))).", data: ["x": String(point.x), "y": String(point.y)])
        } catch {
            return .computerUseFailure(error)
        }
    }
}
