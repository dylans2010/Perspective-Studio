import Foundation

/// Presses a single named key.
public struct ComputerKeyboardPressTool: AssistTool {
    public let id = "computer_keyboard_press"
    public let name = "Keyboard Press"
    public let description = "Presses one named key: return (enter), escape, tab, delete (backspace), forwarddelete, space, left/right/up/down arrows, home, end, pageup, pagedown, f1-f17, or a single letter/digit/punctuation key. For key combinations with modifiers, use computer_keyboard_shortcut instead."

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: description,
            properties: [
                "key": JSONSchema(type: "string", description: "The key name, e.g. \"return\", \"escape\", \"tab\", \"delete\", \"down\", \"f5\", \"a\".")
            ],
            required: ["key"]
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
        guard let key = ComputerUseArguments.string(input, "key") else {
            return ComputerUseError.invalidArgument("computer_keyboard_press requires a 'key' argument.").result
        }
        do {
            try ComputerUseKeyboard.pressKey(named: key)
            return ComputerUseService.success("Pressed key \"\(key)\". Observe the result before assuming its effect.", data: ["key": key])
        } catch {
            return .computerUseFailure(error)
        }
    }
}
