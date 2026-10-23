import Foundation

/// Re-observes the desktop and checks one explicit condition,
/// returning evidence for met / not-met.
public struct ComputerVerifyStateTool: AssistTool {
    public let id = "computer_verify_state"
    public let name = "Verify State"
    public let description = "Re-observes the current state and checks it against one explicit condition, returning met=true/false plus the observed evidence. Conditions: app_frontmost and app_running (bundleId/name/pid), window_exists (titleContains, optional pid), element_exists (role/title/label/identifier/value query, optional pid/bundleId/appName), element_value_contains (element query + expectedValue), text_on_screen (text, via OCR). Use this after any meaningful action instead of assuming it worked."

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: description,
            properties: [
                "condition": JSONSchema(type: "string", description: "The condition to check.", enumValues: ["app_frontmost", "app_running", "window_exists", "element_exists", "element_value_contains", "text_on_screen"]),
                "bundleId": JSONSchema(type: "string", description: "For app conditions / element target app."),
                "name": JSONSchema(type: "string", description: "For app conditions: application name."),
                "pid": JSONSchema(type: "integer", description: "For app conditions / element target app / window owner."),
                "appName": JSONSchema(type: "string", description: "For element conditions: target application name."),
                "titleContains": JSONSchema(type: "string", description: "For window_exists: window title substring."),
                "role": JSONSchema(type: "string", description: "For element conditions: role (exact)."),
                "title": JSONSchema(type: "string", description: "For element conditions: title contains."),
                "label": JSONSchema(type: "string", description: "For element conditions: label contains."),
                "identifier": JSONSchema(type: "string", description: "For element conditions: identifier (exact)."),
                "value": JSONSchema(type: "string", description: "For element conditions: value contains."),
                "expectedValue": JSONSchema(type: "string", description: "For element_value_contains: substring the element's value must contain."),
                "text": JSONSchema(type: "string", description: "For text_on_screen: text OCR must find.")
            ],
            required: ["condition"]
        )
    }

    public init() {}

    public var capability: ToolCapability { .computerUse }
    public var riskLevel: ToolRiskLevel { .safeRead }
    public var requiredPermission: ToolPermissionRequirement { .accessibility }

    public func execute(input: [String: Any], context: AssistContext) async throws -> AssistToolResult {
        if let gate = ComputerUseService.gate(toolID: id, input: input, permissions: []) {
            return gate
        }
        #if !os(macOS)
        return ComputerUseError.platformUnavailable.result
        #else
        do {
            let outcome = try await ComputerUseVerification.evaluate(input: input)
            return ComputerUseService.success(
                "Verification of \"\(outcome.condition)\": \(outcome.met ? "MET" : "NOT MET"). Evidence: \(outcome.evidence)",
                data: ["condition": outcome.condition, "met": outcome.met ? "true" : "false", "evidence": outcome.evidence]
            )
        } catch {
            return .computerUseFailure(error)
        }
        #endif
    }
}
