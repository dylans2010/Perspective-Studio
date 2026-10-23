#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// Progress of a tool the system model called, reported while it runs so the
/// chat UI can show the same call records it shows for MLX agent runs.
nonisolated enum FoundationModelToolEvent: Sendable {
    case started(toolID: String, arguments: [String: String])
    case finished(toolID: String, result: AssistToolResult)
}

/// Adapts one `AssistTool` into a native Foundation Models `Tool`.
///
/// The system model is trained to call tools through this protocol rather than
/// by emitting JSON text, so the agent runtime hands it these bridges instead
/// of the `TOOL_CALL {...}` prompt used on the MLX path. Arguments arrive as
/// `GeneratedContent`, which is converted back into the untyped dictionary
/// `ToolsRegistry` already validates and executes.
@available(macOS 26.0, *)
nonisolated struct AssistToolBridge: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let toolID: String
    let name: String
    let description: String
    let parameters: GenerationSchema
    let context: AssistContext
    let onEvent: (@Sendable (FoundationModelToolEvent) -> Void)?

    @MainActor
    init(
        tool: any AssistTool,
        context: AssistContext,
        onEvent: (@Sendable (FoundationModelToolEvent) -> Void)? = nil
    ) throws {
        self.toolID = tool.id
        self.name = tool.name
        self.description = tool.description
        self.parameters = try Self.parametersSchema(for: tool.parametersSchema)
        self.context = context
        self.onEvent = onEvent
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let input = Self.argumentsDictionary(from: arguments)
        let preview = input.mapValues { String(describing: $0) }
        onEvent?(.started(toolID: toolID, arguments: preview))

        // The registry is main-actor isolated; hop for both the lookup and the
        // call so tool-side UI state stays on the main actor.
        let registry = await ToolsRegistry.shared
        let result = try await registry.execute(toolId: toolID, arguments: input, context: context)

        onEvent?(.finished(toolID: toolID, result: result))
        return result.output
    }
}

// MARK: - JSON Schema → GenerationSchema

@available(macOS 26.0, *)
extension AssistToolBridge {
    /// Converts the registry's JSON Schema description into the dynamic schema
    /// the framework uses to constrain tool arguments.
    @MainActor
    static func parametersSchema(for json: JSONSchema) throws -> GenerationSchema {
        let root = try dynamicSchema(for: json, name: "arguments")
        return try GenerationSchema(root: root, dependencies: [])
    }

    @MainActor
    private static func dynamicSchema(
        for json: JSONSchema,
        name: String
    ) throws -> DynamicGenerationSchema {
        switch json.type {
        case "string":
            if let choices = json.enumValues, !choices.isEmpty {
                return DynamicGenerationSchema(name: name, description: json.description, anyOf: choices)
            }
            return DynamicGenerationSchema(type: String.self)
        case "number":
            return DynamicGenerationSchema(type: Double.self)
        case "integer":
            return DynamicGenerationSchema(type: Int.self)
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)
        case "array":
            let itemSchema = try arrayItemSchema(json.items, name: name + "Item")
            return DynamicGenerationSchema(arrayOf: itemSchema)
        case "object":
            let required = Set(json.required ?? [])
            let properties = try (json.properties ?? [:])
                .sorted { $0.key < $1.key }
                .map { key, value in
                    DynamicGenerationSchema.Property(
                        name: key,
                        description: value.description,
                        schema: try dynamicSchema(for: value, name: key),
                        isOptional: !required.contains(key)
                    )
                }
            return DynamicGenerationSchema(name: name, description: json.description, properties: properties)
        default:
            return DynamicGenerationSchema(type: String.self)
        }
    }

    @MainActor
    private static func arrayItemSchema(
        _ items: JSONSchemaItems?,
        name: String
    ) throws -> DynamicGenerationSchema {
        if case .single(let schema)? = items {
            return try dynamicSchema(for: schema, name: name)
        }
        return DynamicGenerationSchema(type: String.self)
    }
}

// MARK: - GeneratedContent → tool arguments

@available(macOS 26.0, *)
extension AssistToolBridge {
    static func argumentsDictionary(from content: GeneratedContent) -> [String: Any] {
        guard case let .structure(properties, _) = content.kind else { return [:] }
        return properties.compactMapValues(anyValue(from:))
    }

    private static func anyValue(from content: GeneratedContent) -> Any? {
        switch content.kind {
        case .null:
            return nil
        case .bool(let value):
            return value
        case .number(let value):
            // Tool schemas distinguish integers from doubles; preserve whole
            // numbers as Int so `as? Int` lookups in tools keep working.
            return value.rounded() == value ? Int(value) : value
        case .string(let value):
            return value
        case .array(let items):
            return items.compactMap(anyValue(from:))
        case .structure(let properties, _):
            return properties.compactMapValues(anyValue(from:))
        @unknown default:
            return nil
        }
    }
}

#endif
