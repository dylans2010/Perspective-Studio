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
    /// The run's shared tool budget: every bridged call claims one slot
    /// before executing, so the framework-driven loop is capped exactly
    /// like the MLX loop. Optional for non-run callers.
    let budget: ToolExecutionBudget?
    /// Per-call timeout, enforced with the same race `ToolExecutor`
    /// uses on the MLX path.
    let toolTimeout: Duration
    let onEvent: (@Sendable (FoundationModelToolEvent) -> Void)?

    @MainActor
    init(
        tool: any AssistTool,
        context: AssistContext,
        budget: ToolExecutionBudget? = nil,
        toolTimeout: Duration = ToolExecutor.defaultTimeout,
        onEvent: (@Sendable (FoundationModelToolEvent) -> Void)? = nil
    ) throws {
        self.toolID = tool.id
        self.name = tool.name
        self.description = tool.description
        self.parameters = try Self.parametersSchema(for: tool.parametersSchema)
        self.context = context
        self.budget = budget
        self.toolTimeout = toolTimeout
        self.onEvent = onEvent
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let input = Self.argumentsDictionary(from: arguments)
        let preview = input.mapValues { String(describing: $0) }
        onEvent?(.started(toolID: toolID, arguments: preview))

        // Run budget first: a call past the run's tool limit executes
        // nothing. The refusal reaches the model as an error result (the
        // framework's tool channel), so it can end the run honestly
        // instead of believing the action ran.
        if let budget, !budget.claim() {
            let refused = AssistToolResult.failure(
                "This run has reached its tool limit (\(budget.limit) actions). No further actions were executed.",
                code: .executionFailed
            )
            onEvent?(.finished(toolID: toolID, result: refused))
            return "ERROR — this action did not run: the run reached its tool limit. Give your final answer from what you already have, and say plainly that the limit stopped further actions."
        }

        // The registry is main-actor isolated; hop for both the lookup and the
        // call so tool-side UI state stays on the main actor. The execution
        // itself is raced against the per-call timeout: a stuck tool must
        // not stall the framework's loop (and the whole run) forever.
        let codableInput = input.mapValues { AnyCodableValue(any: $0) }
        let toolID = self.toolID
        let context = self.context
        let timeout = self.toolTimeout
        let result: AssistToolResult = await withTaskGroup(of: AssistToolResult?.self) { group in
            group.addTask {
                do {
                    let registry = await ToolsRegistry.shared
                    return try await registry.execute(
                        toolId: toolID,
                        arguments: codableInput.mapValues(\.anyValue),
                        context: context
                    )
                } catch {
                    return .failure(error.localizedDescription, code: .executionFailed)
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            if let first {
                return first
            }
            let limit = Int(GenerationRun.seconds(from: timeout).rounded(.up))
            return .failure(
                "The action did not finish within \(limit)s and was stopped. Its result is unknown — do not report it as done.",
                code: .executionFailed
            )
        }

        onEvent?(.finished(toolID: toolID, result: result))

        // A failed call must reach the model as an error, not as ordinary
        // output it can summarize into a success story. The framework's tool
        // result channel is this return value, so the failure is stated there.
        guard result.success else {
            return "ERROR — this action did not complete successfully: \(result.error ?? result.output)\nDo not describe it as done. Report the failure in plain language and choose a different next step."
        }
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
