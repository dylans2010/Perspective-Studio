import Foundation

/// Executes a modifier+key shortcut, e.g. "command+shift+p".
public struct ComputerKeyboardShortcutTool: AssistTool {
    public let id = "computer_keyboard_shortcut"
    public let name = "Keyboard Shortcut"
    public let description = "Executes a keyboard shortcut given as modifiers plus a key joined with '+', e.g. \"command+s\", \"command+shift+p\", \"option+tab\", \"control+left\". Modifiers: command (cmd), shift, option (alt), control (ctrl), fn. The key must be a supported key name (see computer_keyboard_press). The spec is validated before any event is sent; malformed shortcuts fail with the reason."

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: description,
            properties: [
                "shortcut": JSONSchema(type: "string", description: "The shortcut, e.g. \"command+shift+p\"."),
                "modifiers": JSONSchema(type: "string", description: "Alternative form: comma-separated modifiers, used with the key argument."),
                "key": JSONSchema(type: "string", description: "Alternative form: the key, used with the modifiers argument.")
            ],
            required: []
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
        var spec = ComputerUseArguments.string(input, "shortcut")
        if spec == nil, let key = ComputerUseArguments.string(input, "key") {
            let modifiers = ComputerUseArguments.string(input, "modifiers") ?? ""
            let modParts = modifiers.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            spec = (modParts + [key]).joined(separator: "+")
        }
        guard let spec else {
            return ComputerUseError.invalidArgument("Provide either 'shortcut' (e.g. \"command+s\") or 'modifiers' + 'key'.").result
        }
        do {
            try ComputerUseKeyboard.shortcut(spec)
            return ComputerUseService.success("Executed shortcut \"\(spec)\". Observe the app state to confirm its effect.", data: ["shortcut": spec])
        } catch {
            return .computerUseFailure(error)
        }
    }
}
