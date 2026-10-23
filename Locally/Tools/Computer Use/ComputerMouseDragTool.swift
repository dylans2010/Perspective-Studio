import Foundation

/// Drags from one global-point coordinate to another with an
/// interpolated path.
public struct ComputerMouseDragTool: AssistTool {
    public let id = "computer_mouse_drag"
    public let name = "Mouse Drag"
    public let description = "Drags with the left mouse button from (fromX, fromY) to (toX, toY), all in global points, along an interpolated path over durationSeconds (default 0.5). Both endpoints are validated against the current displays. Only drag when the source element and destination are both clearly identified from a fresh observation — do not drag speculatively."

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: description,
            properties: [
                "fromX": JSONSchema(type: "number", description: "Start X in global points."),
                "fromY": JSONSchema(type: "number", description: "Start Y in global points."),
                "toX": JSONSchema(type: "number", description: "End X in global points."),
                "toY": JSONSchema(type: "number", description: "End Y in global points."),
                "durationSeconds": JSONSchema(type: "number", description: "Drag duration in seconds (default 0.5, max 5). Longer drags are more reliable for sliders and canvas apps.")
            ],
            required: ["fromX", "fromY", "toX", "toY"]
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
        guard let fromX = ComputerUseArguments.double(input, "fromX"),
              let fromY = ComputerUseArguments.double(input, "fromY"),
              let toX = ComputerUseArguments.double(input, "toX"),
              let toY = ComputerUseArguments.double(input, "toY") else {
            return ComputerUseError.invalidArgument("computer_mouse_drag requires numeric fromX, fromY, toX and toY arguments.").result
        }
        let duration = min(max(ComputerUseArguments.double(input, "durationSeconds") ?? 0.5, 0), 5)
        do {
            try await ComputerUseMouse.drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY, durationSeconds: duration)
            return ComputerUseService.success(
                "Dragged from (\(ComputerUseRect.format(fromX)), \(ComputerUseRect.format(fromY))) to (\(ComputerUseRect.format(toX)), \(ComputerUseRect.format(toY))). The drag was dispatched; verify the resulting state before assuming the drop had the intended effect.",
                data: ["fromX": String(fromX), "fromY": String(fromY), "toX": String(toX), "toY": String(toY)]
            )
        } catch {
            return .computerUseFailure(error)
        }
    }
}
