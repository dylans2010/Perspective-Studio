import Foundation
#if os(macOS)
import ApplicationServices
#endif

/// Performs an accessibility action on a uniquely identified element,
/// or sets its value — preferred over coordinate clicking when the
/// element exposes the action.
public struct ComputerPerformAccessibilityActionTool: AssistTool {
    public let id = "computer_perform_accessibility_action"
    public let name = "Perform Accessibility Action"
    public let description = "Performs an accessibility action on ONE element, identified either by a query (role/title/label/identifier/value — it must match exactly one element, otherwise the call fails with the candidates) or by x/y coordinates (the element at that global point). Default action is AXPress. Set action to \"set_value\" with a value argument to write the element's value attribute instead (text fields, sliders). After the action, the element is re-read and its new state reported — the result distinguishes 'action accepted' from the observed state."

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: description,
            properties: [
                "pid": JSONSchema(type: "integer", description: "Target application process id."),
                "bundleId": JSONSchema(type: "string", description: "Target application bundle identifier."),
                "appName": JSONSchema(type: "string", description: "Target application name."),
                "role": JSONSchema(type: "string", description: "Query: element role (exact)."),
                "title": JSONSchema(type: "string", description: "Query: element title contains."),
                "label": JSONSchema(type: "string", description: "Query: element label contains."),
                "identifier": JSONSchema(type: "string", description: "Query: accessibility identifier (exact)."),
                "x": JSONSchema(type: "number", description: "Alternative targeting: global-point x of the element."),
                "y": JSONSchema(type: "number", description: "Alternative targeting: global-point y of the element."),
                "action": JSONSchema(type: "string", description: "The accessibility action to perform, e.g. AXPress (default), AXShowMenu, AXIncrement, AXDecrement, AXConfirm, AXCancel — or \"set_value\" to set the value attribute. The element must advertise the action."),
                "value": JSONSchema(type: "string", description: "For action \"set_value\": the value to write.")
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
        #if !os(macOS)
        return ComputerUseError.platformUnavailable.result
        #else
        do {
            let action = ComputerUseArguments.string(input, "action") ?? "AXPress"
            let element: AXUIElement
            let before: ComputerUseElementSnapshot
            if let point = ComputerUseArguments.point(input) {
                let found = try ComputerUseAccessibility.elementAt(pointX: point.x, pointY: point.y)
                element = found.element
                before = found.snapshot
            } else {
                let pid = try await ComputerUseVerification.resolvedPID(input)
                let query = ComputerUseAccessibility.Query(
                    role: ComputerUseArguments.string(input, "role"),
                    title: ComputerUseArguments.string(input, "title"),
                    label: ComputerUseArguments.string(input, "label"),
                    identifier: ComputerUseArguments.string(input, "identifier"),
                    value: nil
                )
                let found = try ComputerUseAccessibility.resolveUniqueElement(pid: pid, query: query)
                element = found.element
                before = found.snapshot
            }

            if action == "set_value" {
                guard let value = ComputerUseArguments.string(input, "value") else {
                    return ComputerUseError.invalidArgument("action \"set_value\" requires the value argument.").result
                }
                try ComputerUseAccessibility.setValue(value, on: element, snapshot: before)
            } else {
                try ComputerUseAccessibility.performAction(action, on: element, snapshot: before)
            }

            // Re-read the element so the result reports observed state,
            // not just "the call did not throw".
            let after = ComputerUseAccessibility.snapshot(of: element)
            return ComputerUseService.success(
                "Performed \(action) on [\(before.summary)]. Element state afterwards: [\(after.summary)]. Treat follow-up state (windows opened, values changed) as unverified until you observe it.",
                data: ["action": action, "elementAfter": ComputerUseArguments.jsonString(after.jsonObject)]
            )
        } catch {
            return .computerUseFailure(error)
        }
        #endif
    }
}
