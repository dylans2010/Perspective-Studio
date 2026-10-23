import Foundation

/// Dumps a bounded accessibility tree for an application (default:
/// the frontmost app), with roles, titles, values, state, frames in
/// global points and advertised actions.
public struct ComputerGetAccessibilityTreeTool: AssistTool {
    public let id = "computer_get_accessibility_tree"
    public let name = "Get Accessibility Tree"
    public let description = "Returns a bounded dump of an application's accessibility tree: role, title/label, identifier, value, enabled/focused state, frame in global points (with centre), advertised actions and child counts. Target the app by pid, bundleId or name; defaults to the frontmost app. Traversal is bounded (maxDepth/maxElements) and truncation is reported. Not every app exposes a complete tree — when it does not, use a screenshot + OCR instead of inventing elements."

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: description,
            properties: [
                "pid": JSONSchema(type: "integer", description: "Target application process id."),
                "bundleId": JSONSchema(type: "string", description: "Target application bundle identifier."),
                "appName": JSONSchema(type: "string", description: "Target application name (exact, case-insensitive)."),
                "maxDepth": JSONSchema(type: "integer", description: "Maximum tree depth (default 6, hard cap 12)."),
                "maxElements": JSONSchema(type: "integer", description: "Maximum elements to return (default 200, hard cap 400).")
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
            let pid = try await ComputerUseVerification.resolvedPID(input)
            let maxDepth = min(max(ComputerUseArguments.int(input, "maxDepth") ?? 6, 1), ComputerUseSafety.Limits.maxAccessibilityDepth)
            let maxElements = min(max(ComputerUseArguments.int(input, "maxElements") ?? 200, 1), ComputerUseSafety.Limits.maxAccessibilityElements)
            let result = ComputerUseAccessibility.treeText(pid: pid, maxDepth: maxDepth, maxElements: maxElements)
            let header = "Accessibility tree for pid \(pid) — \(result.visited) element(s)\(result.truncated ? " (TRUNCATED at the requested bounds; narrow with a deeper/wider call or computer_find_ui_element)" : ""):"
            return ComputerUseService.success("\(header)\n\(result.text)", data: [
                "pid": String(pid),
                "elementCount": String(result.visited),
                "truncated": result.truncated ? "true" : "false"
            ])
        } catch {
            return .computerUseFailure(error)
        }
        #endif
    }
}
