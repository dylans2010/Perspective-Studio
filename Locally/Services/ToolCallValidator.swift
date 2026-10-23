import Foundation

// MARK: - Tool Contract

/// One registered tool's call contract: the identity the dispatcher resolves
/// against and the schema the arguments are checked against.
///
/// A contract is a snapshot of an `AssistTool` taken when a run starts. The
/// registry stays the source of truth; the snapshot exists so validation is a
/// pure function over value types (no main-actor hop inside the loop, and the
/// validation rules are directly testable).
public struct ToolContract: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let toolDescription: String
    /// `nil` means no schema is available (an ids-only catalog): identity is
    /// still resolved, argument validation is skipped. Production catalogs are
    /// always built from real tools, so their schemas are present.
    public let schema: JSONSchema?
    public let riskLevel: ToolRiskLevel

    public nonisolated var acceptsAnyArguments: Bool {
        switch schema {
        case .none: true
        case .some: false
        }
    }

    public nonisolated init(
        id: String,
        name: String,
        toolDescription: String,
        schema: JSONSchema?,
        riskLevel: ToolRiskLevel
    ) {
        self.id = id
        self.name = name
        self.toolDescription = toolDescription
        self.schema = schema
        self.riskLevel = riskLevel
    }

    @MainActor
    public init(tool: any AssistTool) {
        self.init(
            id: tool.id,
            name: tool.name,
            toolDescription: tool.description,
            schema: tool.parametersSchema,
            riskLevel: tool.riskLevel
        )
    }

    /// Every argument key the tool declares — what a rejection message lists
    /// so the model can correct itself.
    public nonisolated var acceptedArgumentKeys: [String] {
        (schema?.properties ?? [:]).keys.sorted()
    }

    /// Argument names the tool cannot run without.
    public nonisolated var requiredArgumentKeys: [String] {
        (schema?.required ?? []).sorted()
    }
}

// MARK: - Tool Catalog

/// The set of tools a run may call, keyed for case-insensitive resolution.
public struct ToolCatalog: Sendable {
    public let contracts: [String: ToolContract]

    public nonisolated init(contracts: [ToolContract]) {
        var keyed: [String: ToolContract] = [:]
        for contract in contracts {
            keyed[contract.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = contract
        }
        self.contracts = keyed
    }

    @MainActor
    public init(tools: [any AssistTool]) {
        self.init(contracts: tools.map(ToolContract.init(tool:)))
    }

    /// Ids-only catalog: id resolution still happens, argument validation is
    /// skipped because no schema is available. Used by callers that only know
    /// a set of ids, and by tests.
    public nonisolated init(permissiveIDs: Set<String>) {
        self.init(contracts: permissiveIDs.map { id in
            ToolContract(
                id: id,
                name: id,
                toolDescription: "",
                schema: nil,
                riskLevel: .safeRead
            )
        })
    }

    public nonisolated var isEmpty: Bool { contracts.isEmpty }

    /// The canonical registry ids, not the caller's spelling.
    public nonisolated var ids: Set<String> { Set(contracts.values.map(\.id)) }

    /// Case-insensitive, whitespace-trimmed lookup.
    public nonisolated func contract(for id: String) -> ToolContract? {
        contracts[id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }
}

// MARK: - Rejection

/// Why a requested call was refused before anything ran.
///
/// Each case carries a model-facing explanation (fed back into the loop so the
/// model can correct itself) and a user-facing summary (shown in the run trace
/// in plain language, never with a raw tool id).
public enum ToolCallRejection: Sendable, Equatable {
    case unknownTool(String)
    case malformedCall
    case missingArgument(toolID: String, key: String)
    case unexpectedArgument(toolID: String, key: String, accepted: [String])
    case wrongArgumentType(toolID: String, key: String, expected: String)
    case valueNotAllowed(toolID: String, key: String, allowed: [String])

    /// Fed to the model in the correction turn. Naming the invented id here is
    /// deliberate: it is model-facing text, and the model needs to know that
    /// this id does not exist so it stops using it.
    public nonisolated var modelFacingExplanation: String {
        switch self {
        case .unknownTool(let requested):
            "No tool with the id \"\(requested)\" is registered in this runtime, so nothing was executed. Only ids from your tool set can run; retrieve a schema from the context index before calling something you are unsure about."
        case .malformedCall:
            "Your tool request could not be read as the required JSON format, so nothing was executed."
        case .missingArgument(let toolID, let key):
            "The call to \(toolID) was missing the required argument \"\(key)\", so nothing was executed."
        case .unexpectedArgument(let toolID, let key, let accepted):
            "The call to \(toolID) included \"\(key)\", which that tool does not accept. Its accepted arguments are: \(accepted.isEmpty ? "(none)" : accepted.joined(separator: ", ")). Nothing was executed."
        case .wrongArgumentType(let toolID, let key, let expected):
            "The argument \"\(key)\" for \(toolID) must be a \(expected). Nothing was executed."
        case .valueNotAllowed(let toolID, let key, let allowed):
            "The argument \"\(key)\" for \(toolID) must be one of: \(allowed.joined(separator: ", ")). Nothing was executed."
        }
    }

    /// Rendered into the run trace. Plain language, no raw ids: the user is
    /// told that nothing ran and why, in human terms.
    public nonisolated var userFacingSummary: String {
        switch self {
        case .unknownTool:
            "The model asked for a capability this app does not have, so nothing was executed."
        case .malformedCall:
            "The model's action request was not readable, so nothing was executed."
        case .missingArgument:
            "The action request was missing a required input, so nothing was executed."
        case .unexpectedArgument:
            "The action request included an input that action does not accept, so nothing was executed."
        case .wrongArgumentType:
            "An input had the wrong type for that action, so nothing was executed."
        case .valueNotAllowed:
            "An input value is not permitted for that action, so nothing was executed."
        }
    }
}

// MARK: - Validated Call

/// A call that passed identity, argument-key, type, and value checks and may
/// now be executed. `toolID` is the canonical registry id; `signature` is a
/// deterministic rendering used by the no-progress guard.
public struct ValidatedToolCall: Sendable, Equatable {
    public let toolID: String
    public let toolName: String
    public let arguments: [String: AnyCodableValue]

    public nonisolated init(toolID: String, toolName: String, arguments: [String: AnyCodableValue]) {
        self.toolID = toolID
        self.toolName = toolName
        self.arguments = arguments
    }

    /// Stable call signature: tool id plus sorted-key JSON of the arguments.
    public nonisolated var signature: String {
        "\(toolID)|\(Self.canonicalArguments(arguments))"
    }

    public nonisolated static func canonicalArguments(_ arguments: [String: AnyCodableValue]) -> String {
        let raw = arguments.mapValues(\.anyValue)
        if let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return String(describing: arguments)
    }
}

public enum ToolCallValidation: Sendable, Equatable {
    case accepted(ValidatedToolCall)
    case rejected(ToolCallRejection)
}

// MARK: - Validator

/// The single validation gate between a model's requested action and a real
/// tool implementation.
///
/// Every call must pass here before the dispatcher touches a tool: the id is
/// resolved against the registry (case-insensitively, and rejection lists the
/// real ids' existence without guessing), argument keys are checked against
/// the tool's published schema, types are checked, and enum-bounded values are
/// checked. Nothing executes on a rejection — a model mentioning a tool, or
/// printing a command in a code block, never reaches an implementation.
public enum ToolCallValidator {

    public nonisolated static func validate(
        toolID: String,
        arguments: [String: AnyCodableValue],
        catalog: ToolCatalog
    ) -> ToolCallValidation {
        guard let contract = catalog.contract(for: toolID) else {
            return .rejected(.unknownTool(toolID.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        if let rejection = validateArguments(arguments, against: contract) {
            return .rejected(rejection)
        }

        return .accepted(ValidatedToolCall(
            toolID: contract.id,
            toolName: contract.name,
            arguments: arguments
        ))
    }

    /// Validates a whole arguments object against a contract's schema:
    /// required keys present, no undeclared keys, every value type-correct.
    public nonisolated static func validateArguments(
        _ arguments: [String: AnyCodableValue],
        against contract: ToolContract
    ) -> ToolCallRejection? {
        guard let schema = contract.schema, !contract.acceptsAnyArguments else { return nil }
        let declared = schema.properties ?? [:]
        let accepted = declared.keys.sorted()

        for key in contract.requiredArgumentKeys where arguments[key] == nil {
            return .missingArgument(toolID: contract.id, key: key)
        }

        for key in arguments.keys.sorted() {
            guard let schema = declared[key] else {
                return .unexpectedArgument(toolID: contract.id, key: key, accepted: accepted)
            }
            guard let value = arguments[key] else { continue }
            if let rejection = validateValue(value, against: schema, toolID: contract.id, key: key) {
                return rejection
            }
        }
        return nil
    }

    private nonisolated static func validateValue(
        _ value: AnyCodableValue,
        against schema: JSONSchema,
        toolID: String,
        key: String
    ) -> ToolCallRejection? {
        switch schema.type {
        case "string":
            guard case .string(let text) = value else {
                return .wrongArgumentType(toolID: toolID, key: key, expected: "string")
            }
            if let allowed = schema.enumValues, !allowed.isEmpty, !allowed.contains(text) {
                return .valueNotAllowed(toolID: toolID, key: key, allowed: allowed)
            }
            return nil

        case "number", "integer":
            // Local models routinely send numbers as strings; accepting a
            // numeric string here is a coercion, not a schema violation.
            let number: Double?
            switch value {
            case .number(let raw): number = raw
            case .string(let text): number = Double(text)
            default: number = nil
            }
            guard let number else {
                return .wrongArgumentType(toolID: toolID, key: key, expected: schema.type == "integer" ? "whole number" : "number")
            }
            if schema.type == "integer", number.rounded() != number {
                return .wrongArgumentType(toolID: toolID, key: key, expected: "whole number")
            }
            return nil

        case "boolean":
            switch value {
            case .bool: return nil
            case .string(let text) where text == "true" || text == "false": return nil
            default: return .wrongArgumentType(toolID: toolID, key: key, expected: "boolean")
            }

        case "array":
            let items: [AnyCodableValue]
            switch value {
            case .array(let raw):
                items = raw
            case .string(let text):
                // Some dispatch paths stringify nested arguments; the tool
                // parses the JSON string itself, so accept it here and leave
                // the value untouched.
                guard let parsed = jsonArray(text) else {
                    return .wrongArgumentType(toolID: toolID, key: key, expected: "array")
                }
                items = parsed
            default:
                return .wrongArgumentType(toolID: toolID, key: key, expected: "array")
            }
            guard case .single(let itemSchema)? = schema.items else { return nil }
            for (index, item) in items.enumerated() {
                if let rejection = validateValue(item, against: itemSchema, toolID: toolID, key: "\(key)[\(index)]") {
                    return rejection
                }
            }
            return nil

        case "object":
            let properties: [String: AnyCodableValue]
            switch value {
            case .object(let raw):
                properties = raw
            case .string(let text):
                guard let parsed = jsonObject(text) else {
                    return .wrongArgumentType(toolID: toolID, key: key, expected: "object")
                }
                properties = parsed
            default:
                return .wrongArgumentType(toolID: toolID, key: key, expected: "object")
            }
            let declared = schema.properties ?? [:]
            for nestedKey in properties.keys.sorted() {
                guard let nestedSchema = declared[nestedKey] else {
                    return .unexpectedArgument(toolID: toolID, key: "\(key).\(nestedKey)", accepted: declared.keys.sorted())
                }
                guard let nestedValue = properties[nestedKey] else { continue }
                if let rejection = validateValue(nestedValue, against: nestedSchema, toolID: toolID, key: "\(key).\(nestedKey)") {
                    return rejection
                }
            }
            for requiredKey in (schema.required ?? []) where properties[requiredKey] == nil {
                return .missingArgument(toolID: toolID, key: "\(key).\(requiredKey)")
            }
            return nil

        default:
            // Unknown schema type: accept rather than block a real capability.
            return nil
        }
    }

    private nonisolated static func jsonObject(_ text: String) -> [String: AnyCodableValue]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object.mapValues { AnyCodableValue(any: $0) }
    }

    private nonisolated static func jsonArray(_ text: String) -> [AnyCodableValue]? {
        guard let data = text.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        return array.map { AnyCodableValue(any: $0) }
    }
}
