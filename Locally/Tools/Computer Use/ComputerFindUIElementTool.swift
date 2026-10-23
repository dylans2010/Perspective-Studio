import Foundation

/// Finds accessibility elements by role/title/label/identifier/value.
public struct ComputerFindUIElementTool: AssistTool {
    public let id = "computer_find_ui_element"
    public let name = "Find UI Element"
    public let description = "Finds accessibility elements in an application matching the given criteria (role and identifier match exactly; title, label and value match as case-insensitive substrings; all supplied criteria must match). Returns every match with its frame/centre in global points and advertised actions, so ambiguity is visible rather than silently resolved. Target the app by pid, bundleId or appName; defaults to the frontmost app."

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: description,
            properties: [
                "pid": JSONSchema(type: "integer", description: "Target application process id."),
                "bundleId": JSONSchema(type: "string", description: "Target application bundle identifier."),
                "appName": JSONSchema(type: "string", description: "Target application name."),
                "role": JSONSchema(type: "string", description: "Accessibility role, e.g. AXButton, AXTextField, AXCheckBox, AXMenuItem."),
                "title": JSONSchema(type: "string", description: "Element title contains this text."),
                "label": JSONSchema(type: "string", description: "Element accessibility label/description contains this text."),
                "identifier": JSONSchema(type: "string", description: "Accessibility identifier (exact match)."),
                "value": JSONSchema(type: "string", description: "Element value contains this text."),
                "maxResults": JSONSchema(type: "integer", description: "Maximum matches to return (default 20, hard cap 50).")
            ],
            required: []
        )
    }

    public init() {}

    public var capability: ToolCapability { .computerUse }
    public var riskLevel: ToolRiskLevel { .safeRead }
    public var requiredPermission: ToolPermissionRequirement { .accessibility }

    public func execute(input: [String: Any], context: AssistContext) async throws -> AssistToolResult {
        if let gate = ComputerUseService.gate(toolID: id, input: input, permissions: [.accessibility]) {
            return gate
        }
        #if !os(macOS)
        return ComputerUseError.platformUnavailable.result
        #else
        do {
            let query = ComputerUseAccessibility.Query(
                role: ComputerUseArguments.string(input, "role"),
                title: ComputerUseArguments.string(input, "title"),
                label: ComputerUseArguments.string(input, "label"),
                identifier: ComputerUseArguments.string(input, "identifier"),
                value: ComputerUseArguments.string(input, "value")
            )
            guard !query.isEmpty else {
                return ComputerUseError.invalidArgument("Provide at least one of role, title, label, identifier or value.").result
            }
            let pid = try await ComputerUseVerification.resolvedPID(input)
            let maxResults = min(max(ComputerUseArguments.int(input, "maxResults") ?? 20, 1), 50)
            let matches = ComputerUseAccessibility.findElements(pid: pid, query: query, maxResults: maxResults)
            if matches.isEmpty {
                return ComputerUseError.notFound("accessibility element matching the query in pid \(pid). The app may not expose it; inspect the tree with computer_get_accessibility_tree or fall back to screenshot + OCR.").result
            }
            let summaries = matches.map { $0.snapshot.summary }
            let json = ComputerUseArguments.jsonString(matches.map { $0.snapshot.jsonObject })
            return ComputerUseService.success(
                "Found \(matches.count) matching element(s) in pid \(pid):\n" + summaries.joined(separator: "\n"),
                data: ["pid": String(pid), "count": String(matches.count), "elements": json],
                suggestedNextActions: ["Act with computer_perform_accessibility_action using the same query (it must match exactly one element), or click the element's centre with computer_mouse_click."]
            )
        } catch {
            return .computerUseFailure(error)
        }
        #endif
    }
}
