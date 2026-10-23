import Foundation
import Observation

// MARK: - Legacy Tool Compatibility Types

public struct ToolDefinition: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let toolDescription: String
    /// Argument keys this tool accepts — anything else is rejected.
    public let allowedArguments: Set<String>
    /// Sensitive tools require explicit user confirmation before every execution.
    public let requiresConfirmation: Bool

    public var displayDescription: String { toolDescription }

    public init(
        id: String,
        name: String,
        toolDescription: String,
        allowedArguments: Set<String>,
        requiresConfirmation: Bool = false
    ) {
        self.id = id
        self.name = name
        self.toolDescription = toolDescription
        self.allowedArguments = allowedArguments
        self.requiresConfirmation = requiresConfirmation
    }
}

public enum ToolError: LocalizedError, Sendable {
    case unknownTool(String)
    case invalidArguments(String)
    case confirmationRequired(String)
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let id): "Unknown tool: \(id)"
        case .invalidArguments(let detail): "Invalid tool arguments: \(detail)"
        case .confirmationRequired(let name): "\(name) needs your confirmation before it runs"
        case .executionFailed(let detail): "Tool failed: \(detail)"
        }
    }
}

// MARK: - Arithmetic Evaluator

/// A recursive-descent arithmetic evaluator for basic math expressions.
public enum ArithmeticExpression {
    public static func evaluate(_ input: String) throws -> Double {
        var parser = Parser(tokens: try tokenize(input))
        let value = try parser.parseExpression()
        guard parser.atEnd else { throw ToolError.invalidArguments("unexpected trailing characters in expression") }
        return value
    }

    private enum Token: Equatable {
        case number(Double)
        case plus, minus, multiply, divide, modulo, power
        case leftParen, rightParen
        case function(String)
    }

    private static func tokenize(_ input: String) throws -> [Token] {
        var tokens: [Token] = []
        var index = input.startIndex
        while index < input.endIndex {
            let char = input[index]
            switch char {
            case " ", "\t": index = input.index(after: index)
            case "+": tokens.append(.plus); index = input.index(after: index)
            case "-": tokens.append(.minus); index = input.index(after: index)
            case "*", "×": tokens.append(.multiply); index = input.index(after: index)
            case "/", "÷": tokens.append(.divide); index = input.index(after: index)
            case "%": tokens.append(.modulo); index = input.index(after: index)
            case "^": tokens.append(.power); index = input.index(after: index)
            case "(": tokens.append(.leftParen); index = input.index(after: index)
            case ")": tokens.append(.rightParen); index = input.index(after: index)
            default:
                if char.isNumber || char == "." {
                    var end = index
                    while end < input.endIndex && (input[end].isNumber || input[end] == ".") {
                        end = input.index(after: end)
                    }
                    guard let value = Double(input[index..<end]) else {
                        throw ToolError.invalidArguments("bad number in expression")
                    }
                    tokens.append(.number(value))
                    index = end
                } else if char.isLetter {
                    var end = index
                    while end < input.endIndex && input[end].isLetter {
                        end = input.index(after: end)
                    }
                    let name = input[index..<end].lowercased()
                    guard name == "sqrt" || name == "abs" else {
                        throw ToolError.invalidArguments("unsupported function '\(name)'")
                    }
                    tokens.append(.function(name))
                    index = end
                } else {
                    throw ToolError.invalidArguments("unsupported character '\(char)' in expression")
                }
            }
        }
        return tokens
    }

    private struct Parser {
        let tokens: [Token]
        var position = 0
        var atEnd: Bool { position >= tokens.count }

        mutating func parseExpression() throws -> Double {
            var value = try parseTerm()
            while !atEnd && (tokens[position] == .plus || tokens[position] == .minus) {
                let op = tokens[position]; position += 1
                let rhs = try parseTerm()
                value = op == .plus ? value + rhs : value - rhs
            }
            return value
        }

        mutating func parseTerm() throws -> Double {
            var value = try parseFactor()
            while !atEnd && (tokens[position] == .multiply || tokens[position] == .divide || tokens[position] == .modulo) {
                let op = tokens[position]; position += 1
                let rhs = try parseFactor()
                switch op {
                case .multiply: value *= rhs
                case .divide:
                    guard rhs != 0 else { throw ToolError.executionFailed("division by zero") }
                    value /= rhs
                default:
                    guard rhs != 0 else { throw ToolError.executionFailed("modulo by zero") }
                    value = value.truncatingRemainder(dividingBy: rhs)
                }
            }
            return value
        }

        mutating func parseFactor() throws -> Double {
            var base = try parseUnary()
            if !atEnd && tokens[position] == .power {
                position += 1
                let exponent = try parseFactor()
                base = pow(base, exponent)
            }
            return base
        }

        mutating func parseUnary() throws -> Double {
            if !atEnd && tokens[position] == .minus {
                position += 1
                return -(try parseUnary())
            }
            return try parsePrimary()
        }

        mutating func parsePrimary() throws -> Double {
            guard !atEnd else { throw ToolError.invalidArguments("unexpected end of expression") }
            switch tokens[position] {
            case .number(let value):
                position += 1
                return value
            case .leftParen:
                position += 1
                let value = try parseExpression()
                guard !atEnd && tokens[position] == .rightParen else {
                    throw ToolError.invalidArguments("missing closing parenthesis")
                }
                position += 1
                return value
            case .function(let name):
                position += 1
                let value = try parsePrimary()
                return name == "sqrt" ? sqrt(value) : abs(value)
            default:
                throw ToolError.invalidArguments("unexpected token in expression")
            }
        }
    }
}

// MARK: - Built-in AssistTool Implementations

/// Built-in Calculator tool implementing AssistTool.
public struct CalculatorAssistTool: AssistTool {
    public let id = "calculator"
    public let name = "Calculator"
    public let description = "Evaluate an arithmetic expression (+ - * / % ^, parentheses, sqrt/abs). Argument: expression."
    public let capability = ToolCapability.general
    public let riskLevel = ToolRiskLevel.safeRead

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: "Evaluates mathematical expressions.",
            properties: [
                "expression": JSONSchema(type: "string", description: "The arithmetic expression to evaluate (e.g. '25 * 4 + sqrt(16)').")
            ],
            required: ["expression"]
        )
    }

    public init() {}

    public func execute(input: [String: Any], context: AssistContext) async throws -> AssistToolResult {
        guard let expression = (input["expression"] ?? input["expr"] ?? input["query"]) as? String,
              !expression.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .failure("Missing required parameter: 'expression'.", code: .missingArgument)
        }
        do {
            let value = try ArithmeticExpression.evaluate(expression)
            let rendered = value == value.rounded() && abs(value) < 1e15 ? "\(Int(value))" : "\(value)"
            let resultStr = "\(expression) = \(rendered)"
            return .success(resultStr, data: ["expression": expression, "result": rendered])
        } catch {
            return .failure("Calculation failed: \(error.localizedDescription)", code: .invalidInput)
        }
    }
}

/// Built-in Date & Time tool implementing AssistTool.
public struct DateTimeAssistTool: AssistTool {
    public let id = "date_time"
    public let name = "Date & Time"
    public let description = "The current local date and time. No arguments."
    public let capability = ToolCapability.general
    public let riskLevel = ToolRiskLevel.safeRead

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: "Returns the current local date, time, and timezone identifier.",
            properties: [:]
        )
    }

    public init() {}

    public func execute(input: [String: Any], context: AssistContext) async throws -> AssistToolResult {
        let now = Date.now
        let timeString = "Local time: \(now.formatted(date: .complete, time: .standard)) (\(TimeZone.current.identifier))"
        return .success(timeString, data: ["iso8601": now.formatted(.iso8601), "timeZone": TimeZone.current.identifier])
    }
}

/// Built-in Mac Hardware Info tool implementing AssistTool.
public struct HardwareInfoAssistTool: AssistTool {
    public let id = "hardware_info"
    public let name = "Mac Hardware Info"
    public let description = "This Mac's total/available memory and OS version. No arguments."
    public let capability = ToolCapability.diagnostics
    public let riskLevel = ToolRiskLevel.safeRead

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: "Returns system hardware facts (RAM, OS version).",
            properties: [:]
        )
    }

    public init() {}

    public func execute(input: [String: Any], context: AssistContext) async throws -> AssistToolResult {
        let summary = "Mac memory: \(RAMService.totalRAMInGB.formatted(.number.precision(.fractionLength(0)))) GB total, \(RAMService.availableRAMForModels.formatted(.number.precision(.fractionLength(1)))) GB available for models. OS: \(ProcessInfo.processInfo.operatingSystemVersionString)."
        return .success(summary, data: [
            "totalRAMGB": "\(RAMService.totalRAMInGB)",
            "availableRAMGB": "\(RAMService.availableRAMForModels)",
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString
        ])
    }
}

/// Built-in Authorized File Search tool implementing AssistTool.
public struct FileSearchAssistTool: AssistTool {
    public let id = "file_search"
    public let name = "Authorized File Search"
    public let description = "Search file names and text contents inside authorized folders or the active workspace. Argument: query."
    public let capability = ToolCapability.fileReading
    public let riskLevel = ToolRiskLevel.safeRead

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: "Searches authorized folders for files matching the given query.",
            properties: [
                "query": JSONSchema(type: "string", description: "Search query string or filename pattern.")
            ],
            required: ["query"]
        )
    }

    public init() {}

    public func execute(input: [String: Any], context: AssistContext) async throws -> AssistToolResult {
        guard let query = (input["query"] ?? input["pattern"]) as? String,
              !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .failure("Missing required parameter: 'query'.", code: .missingArgument)
        }

        var searchFolders: [URL] = ToolsRegistry.shared.authorizedFolders
        if !searchFolders.contains(where: { $0.path == context.workspaceRoot.path }) {
            searchFolders.append(context.workspaceRoot)
        }

        let needle = query.lowercased()
        let resultText = await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var matches: [String] = []
            var scanned = 0
            let textExtensions: Set<String> = ["txt", "md", "swift", "json", "csv", "log", "py", "ts", "js", "html", "xml", "yaml", "yml"]

            for folder in searchFolders {
                guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { continue }
                while let fileURL = enumerator.nextObject() as? URL {
                    if matches.count >= 25 || scanned >= 600 { break }
                    scanned += 1

                    if fileURL.lastPathComponent.lowercased().contains(needle) {
                        matches.append("Name match: \(fileURL.path)")
                        continue
                    }

                    guard textExtensions.contains(fileURL.pathExtension.lowercased()),
                          let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2_000_000,
                          let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

                    for (lineIndex, line) in contents.components(separatedBy: "\n").enumerated() where line.lowercased().contains(needle) {
                        matches.append("\(fileURL.lastPathComponent):\(lineIndex + 1): \(line.trimmingCharacters(in: .whitespaces).prefix(120))")
                        break
                    }
                }
            }
            return matches.isEmpty ? "No matches for '\(query)' in the authorized search locations." : matches.joined(separator: "\n")
        }.value

        return .success(resultText, data: ["query": query])
    }
}

/// Built-in Model Library Lookup tool implementing AssistTool.
public struct ModelLibraryAssistTool: AssistTool {
    public let id = "model_library"
    public let name = "Model Library Lookup"
    public let description = "List installed local models and whether each is complete/validated. Optional argument: query."
    public let capability = ToolCapability.diagnostics
    public let riskLevel = ToolRiskLevel.safeRead

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: "Looks up installed models on disk.",
            properties: [
                "query": JSONSchema(type: "string", description: "Optional filter string to match model names or IDs.")
            ]
        )
    }

    public init() {}

    public func execute(input: [String: Any], context: AssistContext) async throws -> AssistToolResult {
        let filterQuery = input["query"] as? String
        let modelIDs = HFHubCache.cachedModelIDs()
        guard !modelIDs.isEmpty else {
            return .success("No models are currently installed.", data: ["count": "0"])
        }

        var lines: [String] = []
        for modelID in modelIDs {
            if let filterQuery, !filterQuery.isEmpty, !modelID.localizedStandardContains(filterQuery) {
                continue
            }
            let validation = ModelArtifactValidator.validate(modelID: modelID)
            lines.append(validation.isComplete
                ? "\(modelID) — complete (\(ByteCountFormatter.string(fromByteCount: validation.totalBytes, countStyle: .file)))"
                : "\(modelID) — INCOMPLETE: \(validation.issues.first ?? "partial download")")
        }

        let output = lines.isEmpty ? "No installed models match '\(filterQuery ?? "")'." : lines.joined(separator: "\n")
        return .success(output, data: ["count": "\(lines.count)"])
    }
}

/// Built-in System Asset Lookup tool implementing AssistTool.
public struct SystemAssetLookupAssistTool: AssistTool {
    public let id = "system_asset_lookup"
    public let name = "System Asset Lookup"
    public let description = "Retrieve the full text of an indexed system prompt or guideline asset. Argument: asset_id (e.g. 'coding_standards', 'system_agent_instructions', 'tool_usage_guidelines', 'response_style')."
    public let capability = ToolCapability.general
    public let riskLevel = ToolRiskLevel.safeRead

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: "Retrieves complete system guidelines or coding standards on demand.",
            properties: [
                "asset_id": JSONSchema(type: "string", description: "The identifier or filename of the system asset (e.g. 'coding_standards', 'tool_usage_guidelines').")
            ],
            required: ["asset_id"]
        )
    }

    public init() {}

    public func execute(input: [String: Any], context: AssistContext) async throws -> AssistToolResult {
        guard let assetID = (input["asset_id"] ?? input["id"] ?? input["name"]) as? String,
              !assetID.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .failure("Missing required parameter: 'asset_id'.", code: .missingArgument)
        }

        if let content = SystemAssetsManager.shared.fetchAssetContent(named: assetID) {
            return .success(content, data: ["asset_id": assetID])
        } else {
            let available = SystemAssetsManager.shared.availableAssets().map(\.id).joined(separator: ", ")
            return .failure("Asset '\(assetID)' not found. Available assets: \(available)", code: .notFound)
        }
    }
}

// MARK: - Legacy Tool Adapter

/// Adapts any AssistTool into a legacy ToolDefinition for backwards compatibility.
private struct AssistToLegacyAdapter {
    static func makeDefinition(from tool: AssistTool) -> ToolDefinition {
        let allowed = Set(tool.parametersSchema.properties?.keys.map { String($0) } ?? [])
        let requiresConfirmation = tool.riskLevel >= .execution || tool.id == "file_search"
        return ToolDefinition(
            id: tool.id,
            name: tool.name,
            toolDescription: tool.description,
            allowedArguments: allowed,
            requiresConfirmation: requiresConfirmation
        )
    }
}

// MARK: - ToolsRegistry Implementation

/// Central registry of all tools available to the Antigravity Agent Harness and model callers.
/// Supports both native AssistTool implementations and backward compatibility with ToolRegistry.
@Observable
@MainActor
public final class ToolsRegistry {
    public static let shared = ToolsRegistry()

    private var registeredTools: [String: any AssistTool] = [:]
    private let authorizedFoldersKey = "toolFileSearchAuthorizedFolders"

    public var authorizedFolders: [URL] {
        get { (UserDefaults.standard.array(forKey: authorizedFoldersKey) as? [String] ?? []).map { URL(fileURLWithPath: $0) } }
        set { UserDefaults.standard.set(newValue.map(\.path), forKey: authorizedFoldersKey) }
    }

    public init() {
        registerBuiltInTools()
    }

    private func registerBuiltInTools() {
        register(tool: CalculatorAssistTool())
        register(tool: DateTimeAssistTool())
        register(tool: HardwareInfoAssistTool())
        register(tool: FileSearchAssistTool())
        register(tool: ModelLibraryAssistTool())
        register(tool: SystemAssetLookupAssistTool())

        // Context index lookup: how the model retrieves full index
        // entries (tool schemas, assets, skills, prompts, project
        // memory) on demand instead of receiving them all up front.
        // Registered here — in ToolsRegistry, the canonical execution
        // registry the MLX harness loop and the Foundation-model runner
        // both execute through — and mirrored into the legacy
        // AssistToolRegistry so the capability-lookup tool can see it too.
        let contextIndexSearch = ContextIndexSearchTool()
        register(tool: contextIndexSearch)
        AssistToolRegistry.shared.register(contextIndexSearch)

        // File and workspace operations
        register(tool: AssistReadFileTool())
        register(tool: AssistWriteFileTool())
        register(tool: AssistAppendFileTool())
        register(tool: AssistCreateFileTool())
        register(tool: AssistDeleteFileTool())
        register(tool: AssistCopyFileTool())
        register(tool: AssistMoveFileTool())
        register(tool: AssistReplaceInFileTool())
        register(tool: AssistInsertCodeBlockTool())

        // Directory operations
        register(tool: AssistReadDirectoryTool())
        register(tool: AssistCreateDirectoryTool())
        register(tool: AssistDeleteDirectoryTool())
        register(tool: AssistChangeDirectoryTool())
        register(tool: AssistTreeViewTool())

        // Search operations
        register(tool: AssistSearchTool())
        register(tool: AssistRegexSearchTool())
        register(tool: AssistSymbolSearchTool())

        // Quality, metrics & diagnostics
        register(tool: AssistTodoScanTool())
        register(tool: AssistFileMetadataTool())
        register(tool: AssistFileTypeBreakdownTool())
        register(tool: AssistDirSizeReportTool())
        register(tool: AssistCodeMetricsTool())
        register(tool: AssistCommentDensityReportTool())
        register(tool: AssistComplexityAnalysisTool())
        register(tool: AssistDeadCodeScanTool())
        register(tool: AssistFunctionSizeReportTool())
        register(tool: AssistToolCapabilityLookupTool())

        // Planning & user interaction
        register(tool: ExecutionPlanTool())
        register(tool: PlanAskUserTool())
        register(tool: ReportToUserTool())

        // Per-project memory (Agent Projects): the agent reads/writes the
        // active project's persistent memory through this tool.
        register(tool: ProjectMemoryTool())

        // Computer Use (macOS desktop automation, built from scratch
        // on ScreenCaptureKit / Accessibility / Vision / CGEvent /
        // NSWorkspace — see Tools/Computer Use/ and the computer_use
        // System Asset). Idempotent: registry keys by tool id.
        ComputerUseToolRegistry.registerAll(into: self)
    }

    // MARK: - AssistTool Registration API

    /// Registers an AssistTool implementation.
    public func register(tool: any AssistTool) {
        registeredTools[tool.id.lowercased()] = tool
    }

    /// Looks up a registered tool by identifier (case-insensitive).
    public func tool(for id: String) -> (any AssistTool)? {
        registeredTools[id.lowercased()]
    }

    /// All registered AssistTool instances sorted by name.
    public var allTools: [any AssistTool] {
        registeredTools.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The canonical ids of every registered tool. These ids are private
    /// protocol tokens: they exist so models can *call* tools, and they must
    /// never appear in user-visible text (`ToolInvocationSanitizer` uses
    /// this set to strip and redact them from model output).
    public var allToolIDs: Set<String> {
        Set(registeredTools.keys)
    }

    /// Formats ONE tool's schema description — the per-tool payload the
    /// context index stores and retrieves. Static and nonisolated (it
    /// only reads the passed tool) so the pure index builder can render
    /// payloads without touching the shared registry.
    public nonisolated static func schemaDescription(for tool: any AssistTool) -> String {
        var lines: [String] = []
        lines.append("- `\(tool.id)`: \(tool.name)")
        lines.append("  Description: \(tool.description)")
        lines.append("  Capability: \(tool.capability.rawValue) | Risk Level: \(tool.riskLevel.rawValue)")
        if let properties = tool.parametersSchema.properties, !properties.isEmpty {
            lines.append("  Arguments:")
            let requiredKeys = Set(tool.parametersSchema.required ?? [])
            for (key, schema) in properties.sorted(by: { $0.key < $1.key }) {
                let isRequired = requiredKeys.contains(key) ? "required" : "optional"
                let desc = schema.description ?? schema.type
                lines.append("    * `\(key)` (\(schema.type), \(isRequired)): \(desc)")
            }
        } else {
            lines.append("  Arguments: None (empty object `{}`)")
        }
        return lines.joined(separator: "\n")
    }

    /// Formats human and model-readable schema descriptions of all registered tools.
    ///
    /// NOTE: prompts no longer call this — sending every schema at once is
    /// exactly what `ContextIndexManager` replaced. The full dump remains
    /// for debugging/UI use; prompts get the index's budgeted selection of
    /// `schemaDescription(for:)` payloads instead.
    public func schemaDescriptions() -> String {
        let blocks = allTools.map { "\n" + Self.schemaDescription(for: $0) }
        return (["Available Tools:"] + blocks).joined(separator: "\n")
    }

    /// Executes a registered tool by ID with arguments and context.
    public func execute(
        toolId: String,
        arguments: [String: Any],
        context: AssistContext
    ) async throws -> AssistToolResult {
        guard let tool = self.tool(for: toolId) else {
            throw ToolError.unknownTool(toolId)
        }

        // Validate required properties if defined
        if let required = tool.parametersSchema.required {
            for key in required where arguments[key] == nil {
                return .failure("Missing required argument: '\(key)'", code: .missingArgument)
            }
        }

        return try await tool.execute(input: arguments, context: context)
    }

    // MARK: - Backwards Compatibility with Legacy ToolRegistry

    /// Legacy tools array used by older UI and services.
    public var tools: [ToolDefinition] {
        allTools.map { AssistToLegacyAdapter.makeDefinition(from: $0) }
    }

    /// Legacy definition lookup.
    public func definition(for id: String) -> ToolDefinition? {
        guard let tool = self.tool(for: id) else { return nil }
        return AssistToLegacyAdapter.makeDefinition(from: tool)
    }

    /// Legacy execute method for String-based dictionary arguments and confirmation gate.
    public func execute(toolID: String, arguments: [String: String], confirmed: Bool) async throws -> String {
        guard let tool = self.tool(for: toolID) else {
            throw ToolError.unknownTool(toolID)
        }

        let definition = AssistToLegacyAdapter.makeDefinition(from: tool)
        for key in arguments.keys where !definition.allowedArguments.isEmpty && !definition.allowedArguments.contains(key) {
            throw ToolError.invalidArguments("unexpected argument '\(key)' for \(tool.name)")
        }
        if definition.requiresConfirmation && !confirmed {
            throw ToolError.confirmationRequired(tool.name)
        }

        let context = AssistContext(workspaceRoot: URL.documentsDirectory)
        var anyArgs: [String: Any] = [:]
        for (k, v) in arguments {
            anyArgs[k] = v
        }

        let result = try await tool.execute(input: anyArgs, context: context)
        if result.success {
            return result.output
        } else {
            throw ToolError.executionFailed(result.error ?? result.output)
        }
    }
}

// MARK: - Legacy Typealias

public typealias ToolRegistry = ToolsRegistry
