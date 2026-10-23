import Foundation
import Observation

struct ToolDefinition: Identifiable, Sendable {
    let id: String
    let name: String
    let toolDescription: String
    /// Argument keys this tool accepts — anything else is rejected.
    let allowedArguments: Set<String>
    /// Sensitive tools (file search) require explicit user confirmation
    /// before every execution, including when a model requests them.
    let requiresConfirmation: Bool

    var displayDescription: String { toolDescription }
}

enum ToolError: LocalizedError {
    case unknownTool(String)
    case invalidArguments(String)
    case confirmationRequired(String)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let id): "Unknown tool: \(id)"
        case .invalidArguments(let detail): "Invalid tool arguments: \(detail)"
        case .confirmationRequired(let name): "\(name) needs your confirmation before it runs"
        case .executionFailed(let detail): "Tool failed: \(detail)"
        }
    }
}

/// Tool registry + execution pipeline (feature K).
///
/// Safety model, by design:
/// - Only the tools listed here exist. There is **no** shell / command tool,
///   and model-generated arguments can never create one.
/// - Arguments are treated as untrusted: keys are allow-listed per tool,
///   values are length-bounded, and file search only ever looks inside
///   folders the user explicitly authorized in the Tools UI.
/// - Sensitive tools require confirmation before execution.
@Observable @MainActor
final class ToolRegistry {
    static let shared = ToolRegistry()

    let tools: [ToolDefinition] = [
        ToolDefinition(
            id: "calculator",
            name: "Calculator",
            toolDescription: "Evaluate an arithmetic expression (+ - * / % ^, parentheses, sqrt/abs). Argument: expression.",
            allowedArguments: ["expression"],
            requiresConfirmation: false
        ),
        ToolDefinition(
            id: "date_time",
            name: "Date & Time",
            toolDescription: "The current local date and time. No arguments.",
            allowedArguments: [],
            requiresConfirmation: false
        ),
        ToolDefinition(
            id: "hardware_info",
            name: "Mac Hardware Info",
            toolDescription: "This Mac's total/available memory and OS version. No arguments.",
            allowedArguments: [],
            requiresConfirmation: false
        ),
        ToolDefinition(
            id: "file_search",
            name: "Authorized File Search",
            toolDescription: "Search file names and text contents inside folders you authorized in Studio → Tools. Argument: query.",
            allowedArguments: ["query"],
            requiresConfirmation: true
        ),
        ToolDefinition(
            id: "model_library",
            name: "Model Library Lookup",
            toolDescription: "List installed models and whether each is complete/validated. Optional argument: query.",
            allowedArguments: ["query"],
            requiresConfirmation: false
        ),
    ]

    private let authorizedFoldersKey = "toolFileSearchAuthorizedFolders"

    var authorizedFolders: [URL] {
        get { (UserDefaults.standard.array(forKey: authorizedFoldersKey) as? [String] ?? []).map { URL(fileURLWithPath: $0) } }
        set { UserDefaults.standard.set(newValue.map(\.path), forKey: authorizedFoldersKey) }
    }

    func definition(for id: String) -> ToolDefinition? {
        tools.first { $0.id == id }
    }

    /// Executes a tool after validating its arguments against the definition.
    /// `confirmed` must be true for tools with `requiresConfirmation`.
    func execute(toolID: String, arguments: [String: String], confirmed: Bool) async throws -> String {
        guard let tool = definition(for: toolID) else {
            throw ToolError.unknownTool(toolID)
        }
        for key in arguments.keys where !tool.allowedArguments.contains(key) {
            throw ToolError.invalidArguments("unexpected argument '\(key)' for \(tool.name)")
        }
        for value in arguments.values where value.count > 500 {
            throw ToolError.invalidArguments("argument value too long")
        }
        if tool.requiresConfirmation && !confirmed {
            throw ToolError.confirmationRequired(tool.name)
        }

        switch toolID {
        case "calculator":
            guard let expression = arguments["expression"], !expression.isEmpty else {
                throw ToolError.invalidArguments("expression is required")
            }
            let value = try ArithmeticExpression.evaluate(expression)
            let rendered = value == value.rounded() && abs(value) < 1e15 ? "\(Int(value))" : "\(value)"
            return "\(expression) = \(rendered)"
        case "date_time":
            return "Local time: \(Date.now.formatted(date: .complete, time: .standard)) (\(TimeZone.current.identifier))"
        case "hardware_info":
            return "Mac memory: \(RAMService.totalRAMInGB.formatted(.number.precision(.fractionLength(0)))) GB total, \(RAMService.availableRAMForModels.formatted(.number.precision(.fractionLength(1)))) GB available for models. OS: \(ProcessInfo.processInfo.operatingSystemVersionString)."
        case "file_search":
            guard let query = arguments["query"], !query.isEmpty else {
                throw ToolError.invalidArguments("query is required")
            }
            return try await Self.searchAuthorizedFolders(query: query, folders: authorizedFolders)
        case "model_library":
            return Self.modelLibrarySummary(query: arguments["query"])
        default:
            throw ToolError.unknownTool(toolID)
        }
    }

    // MARK: - File search (bounded, authorized folders only)

    private nonisolated static func searchAuthorizedFolders(query: String, folders: [URL]) async throws -> String {
        guard !folders.isEmpty else {
            throw ToolError.executionFailed("no folders authorized — add one in Studio → Tools first")
        }
        let needle = query.lowercased()
        return await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var matches: [String] = []
            var scanned = 0
            let textExtensions: Set<String> = ["txt", "md", "swift", "json", "csv", "log", "py", "ts", "js", "html", "xml", "yaml", "yml"]
            for folder in folders {
                guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { continue }
                for case let fileURL as URL in enumerator {
                    if matches.count >= 20 || scanned >= 500 { break }
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
            return matches.isEmpty ? "No matches for '\(query)' in the authorized folders." : matches.joined(separator: "\n")
        }.value
    }

    private static func modelLibrarySummary(query: String?) -> String {
        let modelIDs = HFHubCache.cachedModelIDs()
        guard !modelIDs.isEmpty else {
            return "No models are installed."
        }
        var lines: [String] = []
        for modelID in modelIDs {
            if let query, !modelID.localizedStandardContains(query) { continue }
            let validation = ModelArtifactValidator.validate(modelID: modelID)
            lines.append(validation.isComplete
                ? "\(modelID) — complete (\(ByteCountFormatter.string(fromByteCount: validation.totalBytes, countStyle: .file)))"
                : "\(modelID) — INCOMPLETE: \(validation.issues.first ?? "partial download")")
        }
        return lines.isEmpty ? "No installed models match." : lines.joined(separator: "\n")
    }
}

/// A small recursive-descent arithmetic evaluator. Deliberately *not* a
/// general expression engine: numbers, + - * / % ^, parentheses, unary minus,
/// and `sqrt(...)` / `abs(...)` only. Anything else is an error.
enum ArithmeticExpression {
    static func evaluate(_ input: String) throws -> Double {
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
                return -try parseUnary()
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
