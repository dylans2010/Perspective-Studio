import Foundation

public struct AssistToolCapabilityLookupTool: AssistTool {
    public let id = "tool_capability_lookup"
    public let name = "Tool Capability Lookup"
    public let description = "Looks up a registered tool's capability, risk level, description, and parameter schema from the live tool registry. Use it to confirm a tool exists and what arguments it takes before calling it."

    public init() {}

    public var capability: ToolCapability { .general }
    public var riskLevel: ToolRiskLevel { .safeRead }

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: "Looks up a tool in the registry.",
            properties: [
                "toolId": JSONSchema(type: "string", description: "A registered tool id, e.g. file_read. Unknown ids are reported with the list of registered ids.")
            ],
            required: ["toolId"]
        )
    }

    public func execute(input: [String: Any], context: AssistContext) async throws -> AssistToolResult {
        guard let toolId = (input["toolId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !toolId.isEmpty else {
            return .failure("Missing required parameter: toolId")
        }
        // The live registry is `ToolsRegistry` — the one the agent loop
        // dispatches through. (`AssistToolRegistry` is a legacy mirror that
        // only ever held the context-index tool, so looking up there reported
        // every real tool as missing.)
        let tool: (any AssistTool)? = await MainActor.run { ToolsRegistry.shared.tool(for: toolId) }
        guard let tool else {
            let available = await MainActor.run { ToolsRegistry.shared.allTools.map(\.id).sorted() }
            return .failure(
                "No registered tool with id '\(toolId)'. Registered ids: \(available.joined(separator: ", ")).",
                code: .notFound
            )
        }
        let schema = tool.parametersSchema
        let required = (schema.required ?? []).joined(separator: ", ")
        let props = (schema.properties?.keys.sorted() ?? []).joined(separator: ", ")
        let output = [
            "Tool: \(tool.id) — \(tool.name)",
            "Capability: \(tool.capability)",
            "Risk level: \(tool.riskLevel)",
            "Read-only: \(tool.isReadOnly), Mutating: \(tool.isMutating)",
            "Description: \(tool.description)",
            "Parameters: \(props.isEmpty ? "(none)" : props)",
            "Required: \(required.isEmpty ? "(none)" : required)",
            "Estimated cost: \(tool.estimatedCost)"
        ].joined(separator: "\n")
        return .success(output, data: [
            "toolId": tool.id, "capability": "\(tool.capability)",
            "riskLevel": "\(tool.riskLevel)", "required": required
        ])
    }
}
