import Foundation

/// Scrolls over a global-point coordinate.
public struct ComputerMouseScrollTool: AssistTool {
    public let id = "computer_mouse_scroll"
    public let name = "Mouse Scroll"
    public let description = "Scrolls at a coordinate in global points. deltaY positive scrolls down, negative scrolls up; deltaX positive scrolls right. Amounts are in pixels of wheel movement (a typical page step is 300-600). The pointer is moved to the coordinate first so the scroll lands on the intended view. Re-observe after scrolling — content positions change."

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: description,
            properties: [
                "x": JSONSchema(type: "number", description: "X coordinate in global points to scroll over."),
                "y": JSONSchema(type: "number", description: "Y coordinate in global points to scroll over."),
                "deltaY": JSONSchema(type: "number", description: "Vertical scroll amount in pixels; positive = down. Default 0."),
                "deltaX": JSONSchema(type: "number", description: "Horizontal scroll amount in pixels; positive = right. Default 0.")
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
            return ComputerUseError.invalidArgument("computer_mouse_scroll requires numeric x and y arguments.").result
        }
        let deltaY = ComputerUseArguments.double(input, "deltaY", "delta_y") ?? 0
        let deltaX = ComputerUseArguments.double(input, "deltaX", "delta_x") ?? 0
        guard deltaX != 0 || deltaY != 0 else {
            return ComputerUseError.invalidArgument("Provide a non-zero deltaY and/or deltaX.").result
        }
        do {
            try ComputerUseMouse.scroll(atX: point.x, y: point.y, deltaX: deltaX, deltaY: deltaY)
            return ComputerUseService.success(
                "Scrolled at (\(ComputerUseRect.format(point.x)), \(ComputerUseRect.format(point.y))) by deltaX \(ComputerUseRect.format(deltaX)), deltaY \(ComputerUseRect.format(deltaY)). Observe again before acting on positions — scrolling moved the content.",
                data: ["x": String(point.x), "y": String(point.y), "deltaX": String(deltaX), "deltaY": String(deltaY)]
            )
        } catch {
            return .computerUseFailure(error)
        }
    }
}
