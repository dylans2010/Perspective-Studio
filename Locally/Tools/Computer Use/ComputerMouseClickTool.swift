import Foundation

/// Clicks a global-point coordinate (validated against live display
/// bounds) with the left or right button.
public struct ComputerMouseClickTool: AssistTool {
    public let id = "computer_mouse_click"
    public let name = "Mouse Click"
    public let description = "Clicks at a coordinate in global points (origin top-left of the main display — the same coordinates screenshots, OCR and accessibility frames use). Coordinates are validated against the current displays; an off-screen target fails instead of clicking blindly. Prefer computer_perform_accessibility_action when the target is an accessibility element with an action. Ground every click in a fresh observation — do not reuse coordinates after the layout may have changed."

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: description,
            properties: [
                "x": JSONSchema(type: "number", description: "X coordinate in global points."),
                "y": JSONSchema(type: "number", description: "Y coordinate in global points."),
                "button": JSONSchema(type: "string", description: "\"left\" (default) or \"right\".", enumValues: ["left", "right"]),
                "clickCount": JSONSchema(type: "integer", description: "1 (default), 2 for a double-click, 3 for triple. Only use more than 1 when the target genuinely needs it (e.g. opening a file, selecting a word).")
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
            return ComputerUseError.invalidArgument("computer_mouse_click requires numeric x and y arguments.").result
        }
        let buttonName = ComputerUseArguments.string(input, "button") ?? "left"
        guard let button = ComputerUseMouse.Button(rawValue: buttonName) else {
            return ComputerUseError.invalidArgument("button must be \"left\" or \"right\" (got \"\(buttonName)\").").result
        }
        let clickCount = ComputerUseArguments.int(input, "clickCount", "click_count") ?? 1
        do {
            try ComputerUseMouse.click(atX: point.x, y: point.y, button: button, clickCount: clickCount)
            return ComputerUseService.success(
                "Clicked (\(ComputerUseRect.format(point.x)), \(ComputerUseRect.format(point.y))) with the \(buttonName) button (count \(clickCount)). This confirms the click was dispatched, not that the app reacted as intended — verify the result (computer_verify_state, a fresh accessibility tree, or a screenshot).",
                data: ["x": String(point.x), "y": String(point.y), "button": buttonName, "clickCount": String(clickCount)]
            )
        } catch {
            return .computerUseFailure(error)
        }
    }
}
