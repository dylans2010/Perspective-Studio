import Foundation

/// Types text into the currently focused field as Unicode key events.
public struct ComputerKeyboardTypeTool: AssistTool {
    public let id = "computer_keyboard_type"
    public let name = "Keyboard Type"
    public let description = "Types text into whatever field currently has keyboard focus, as real Unicode key events (newlines become Return presses, tabs become Tab presses). Focus is the caller's responsibility: focus the target first (click it, or check the focused element via computer_get_accessibility_tree) — this tool reports only that the events were dispatched, never that a specific field received them. Verify by reading the field's value afterwards. The typed text is never echoed in the result (it may be sensitive). For app shortcuts use computer_keyboard_shortcut; to write a field you have identified by accessibility, computer_perform_accessibility_action with action set_value is more reliable."

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: description,
            properties: [
                "text": JSONSchema(type: "string", description: "The text to type (max 10000 characters per call).")
            ],
            required: ["text"]
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
        guard let text = input["text"] as? String else {
            return ComputerUseError.invalidArgument("computer_keyboard_type requires a string 'text' argument.").result
        }
        do {
            try await ComputerUseKeyboard.type(text)
            return ComputerUseService.success(
                "Typed \(ComputerUseSafety.redactedTextSummary(text)) into the focused field. Delivery to the intended field is NOT verified — read the field back (accessibility value or OCR) before assuming the text landed.",
                data: ["characterCount": String(text.count)]
            )
        } catch {
            return .computerUseFailure(error)
        }
    }
}
