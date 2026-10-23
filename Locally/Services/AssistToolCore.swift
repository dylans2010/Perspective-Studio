import Foundation
import os

// MARK: - JSON Value & Schema

public enum JSONValue: Codable, Sendable, Hashable {
    case null
    case string(String)
    case number(Double)
    case boolean(Bool)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .boolean(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([JSONValue].self) {
            self = .array(arr)
        } else if let dict = try? container.decode([String: JSONValue].self) {
            self = .object(dict)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown JSON value")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .string(let s):
            try container.encode(s)
        case .number(let n):
            try container.encode(n)
        case .boolean(let b):
            try container.encode(b)
        case .array(let arr):
            try container.encode(arr)
        case .object(let dict):
            try container.encode(dict)
        }
    }
}

public indirect enum JSONSchemaItems: Codable, Sendable, Hashable {
    case single(JSONSchema)
    case array([JSONSchema])
    case dictionary([String: JSONSchema])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let schema = try? container.decode(JSONSchema.self) {
            self = .single(schema)
        } else if let schemas = try? container.decode([JSONSchema].self) {
            self = .array(schemas)
        } else if let dict = try? container.decode([String: JSONSchema].self) {
            if dict.count == 1, let schema = dict["type"] {
                self = .single(schema)
            } else {
                self = .dictionary(dict)
            }
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Invalid JSONSchemaItems")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .single(let schema):
            try container.encode(schema)
        case .array(let schemas):
            try container.encode(schemas)
        case .dictionary(let dict):
            if dict.count == 1, let schema = dict["type"] {
                try container.encode(schema)
            } else {
                try container.encode(dict)
            }
        }
    }
}

public struct JSONSchema: Codable, Sendable, Hashable {
    public let type: String
    public let description: String?
    public let properties: [String: JSONSchema]?
    public let required: [String]?
    public let items: JSONSchemaItems?
    public let enumValues: [String]?

    public init(
        type: String,
        description: String? = nil,
        properties: [String: JSONSchema]? = nil,
        required: [String]? = nil,
        items: JSONSchema? = nil,
        enumValues: [String]? = nil
    ) {
        self.type = type
        self.description = description
        self.properties = properties
        self.required = required
        self.items = items.map { .single($0) }
        self.enumValues = enumValues
    }

    public init(
        type: String,
        description: String? = nil,
        properties: [String: JSONSchema]? = nil,
        required: [String]? = nil,
        items: JSONSchemaItems?,
        enumValues: [String]? = nil
    ) {
        self.type = type
        self.description = description
        self.properties = properties
        self.required = required
        self.items = items
        self.enumValues = enumValues
    }

    public init(
        type: String,
        description: String? = nil,
        properties: [String: JSONSchema]? = nil,
        required: [String]? = nil,
        items: [String: JSONSchema]?,
        enumValues: [String]? = nil
    ) {
        self.type = type
        self.description = description
        self.properties = properties
        self.required = required
        if let items = items {
            if items.count == 1, let schema = items["type"] {
                self.items = .single(schema)
            } else {
                self.items = .dictionary(items)
            }
        } else {
            self.items = nil
        }
        self.enumValues = enumValues
    }

    private enum CodingKeys: String, CodingKey {
        case type, description, properties, required, items
        case enumValues = "enum"
    }
}

// MARK: - Tool Capabilities & Risk Levels

public enum ToolCapability: String, Codable, Sendable, CaseIterable {
    case repositoryDiscovery = "Repository Discovery"
    case fileReading = "File Reading"
    case fileModification = "File Modification"
    case compilation = "Compilation & Build"
    case testing = "Testing & QA"
    case diagnostics = "Diagnostics & Profiling"
    case gitOperations = "Version Control (Git)"
    case systemExecution = "System & Shell Execution"
    case planning = "Task Planning"
    case memory = "Agent Memory"
    case computerUse = "Computer Use"
    case general = "General"
}

public enum ToolRiskLevel: String, Codable, Sendable, Comparable {
    case safeRead = "Safe Read"
    case safeMutation = "Safe Mutation"
    case execution = "Execution"
    case potentiallyDestructive = "Potentially Destructive"
    case externalSideEffect = "External Side Effect"

    private var rank: Int {
        switch self {
        case .safeRead: return 0
        case .safeMutation: return 1
        case .execution: return 2
        case .potentiallyDestructive: return 3
        case .externalSideEffect: return 4
        }
    }

    public static func < (lhs: ToolRiskLevel, rhs: ToolRiskLevel) -> Bool {
        return lhs.rank < rhs.rank
    }
}

public enum ToolOutputFormat: String, Codable, Sendable {
    case text = "Text"
    case image = "Image"
    case video = "Video"
    case file = "File"
    case structuredData = "Structured Data"
}

public enum ToolPermissionRequirement: String, Codable, Sendable {
    case none = "None"
    case screenRecording = "Screen Recording"
    case accessibility = "Accessibility"
    case fileSystem = "File System"
    case terminalExecution = "Terminal Execution"
}

public struct ToolMetadata: Codable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let capability: ToolCapability
    public let riskLevel: ToolRiskLevel
    public let isReadOnly: Bool
    public let isMutating: Bool
    public let requiresVerificationAfterward: Bool
    public let outputFormat: ToolOutputFormat
    public let requiredPermission: ToolPermissionRequirement
    public let prerequisites: [String]
    public let supportedOperations: [String]
    public let knownLimitations: [String]
    public let canChainResult: Bool
    public let isDestructive: Bool
    public let resourceScope: String

    public init(
        id: String,
        name: String,
        description: String,
        capability: ToolCapability,
        riskLevel: ToolRiskLevel,
        isReadOnly: Bool,
        isMutating: Bool,
        requiresVerificationAfterward: Bool,
        outputFormat: ToolOutputFormat = .text,
        requiredPermission: ToolPermissionRequirement = .none,
        prerequisites: [String] = [],
        supportedOperations: [String] = [],
        knownLimitations: [String] = [],
        canChainResult: Bool = true,
        isDestructive: Bool = false,
        resourceScope: String = "Workspace Project"
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.capability = capability
        self.riskLevel = riskLevel
        self.isReadOnly = isReadOnly
        self.isMutating = isMutating
        self.requiresVerificationAfterward = requiresVerificationAfterward
        self.outputFormat = outputFormat
        self.requiredPermission = requiredPermission
        self.prerequisites = prerequisites
        self.supportedOperations = supportedOperations
        self.knownLimitations = knownLimitations
        self.canChainResult = canChainResult
        self.isDestructive = isDestructive
        self.resourceScope = resourceScope
    }
}

public enum AssistSafetyLevel: String, Codable, CaseIterable, Sendable {
    case conservative = "Conservative"
    case balanced = "Balanced"
    case aggressive = "Aggressive"
}

public enum ExecutionMode: String, Codable, Sendable, CaseIterable {
    case plan = "Plan"
    case autopilot = "Autopilot"

    public var systemInstruction: String {
        switch self {
        case .autopilot:
            return "Execute autonomously to completion. Never announce mode status. Formulate steps internally, make required code changes, build, and verify without pausing to ask confirmation on routine choices."
        case .plan:
            return "Plan first and confirm each step."
        }
    }
}

public enum AssistToolErrorCode: String, Codable, Sendable, CaseIterable {
    case missingArgument
    case invalidInput
    case notFound
    case permissionDenied
    case executionFailed
    case timeout
    case cancelled
    case resourceExhausted
    case unsupportedOperation
    case unknown

    public var recoveryHint: String {
        switch self {
        case .missingArgument:
            return "Re-run the tool with all required parameters filled in, following the tool's parameter schema."
        case .invalidInput:
            return "Fix the invalid parameter value (check ranges, types, and allowed values) and re-run the tool."
        case .notFound:
            return "Verify the path or identifier exists and re-run the tool with the corrected value."
        case .permissionDenied:
            return "Request the needed permission or choose a target inside the allowed workspace, then re-run."
        case .executionFailed:
            return "Inspect the diagnostics, fix the underlying cause, then re-run the tool."
        case .timeout:
            return "Re-run with a narrower scope or smaller input so it completes within the time limit."
        case .cancelled:
            return "Re-issue the request when you are ready for it to run to completion."
        case .resourceExhausted:
            return "Reduce the size or scope of the request and try again."
        case .unsupportedOperation:
            return "Choose a different tool or approach that supports this operation on the current platform."
        case .unknown:
            return "Re-run the tool; if the failure repeats, narrow the request and inspect the diagnostics."
        }
    }
}

public enum AssistToolDataKey {
    public static let content = "content"
    public static let explanation = "explanation"
    public static let diff = "diff"
    public static let testResults = "test_results"
    public static let buildStatus = "build_status"
    public static let searchResults = "results"
    public static let planId = "planId"
    public static let breakdown = "breakdown"
    public static let count = "count"
    public static let truncated = "truncated"
    public static let path = "path"
    public static let exitCode = "exitCode"
    public static let durationMs = "durationMs"
    public static let stdout = "stdout"
    public static let stderr = "stderr"
    public static let startLine = "startLine"
    public static let endLine = "endLine"
    public static let totalLines = "totalLines"
    public static let fullyAvailable = "fullyAvailable"
}

// MARK: - AssistToolResult

public struct AssistToolResult: Codable, Sendable {
    public let success: Bool
    public let output: String
    public let data: [String: String]?
    public let error: String?
    public let errorCode: Int?
    public let diagnostics: [String]
    public let filesChanged: [String]
    public let diff: String?
    public let duration: TimeInterval
    public let exitCode: Int32?
    public let suggestedNextActions: [String]
    public let beforeContent: String?
    public let afterContent: String?
    public var toolErrorCode: AssistToolErrorCode?

    public init(
        success: Bool,
        output: String,
        data: [String: String]? = nil,
        error: String? = nil,
        errorCode: Int? = nil,
        diagnostics: [String] = [],
        filesChanged: [String] = [],
        diff: String? = nil,
        duration: TimeInterval = 0,
        exitCode: Int32? = nil,
        suggestedNextActions: [String] = [],
        beforeContent: String? = nil,
        afterContent: String? = nil,
        toolErrorCode: AssistToolErrorCode? = nil
    ) {
        self.success = success
        self.output = output
        self.data = data
        self.error = error
        self.errorCode = errorCode
        self.diagnostics = diagnostics
        self.filesChanged = filesChanged
        self.diff = diff
        self.duration = duration
        self.exitCode = exitCode
        self.suggestedNextActions = suggestedNextActions
        self.beforeContent = beforeContent
        self.afterContent = afterContent
        self.toolErrorCode = toolErrorCode
    }

    public static func success(
        _ output: String,
        data: [String: String]? = nil,
        diff: String? = nil,
        filesChanged: [String] = [],
        diagnostics: [String] = [],
        suggestedNextActions: [String] = [],
        duration: TimeInterval = 0
    ) -> AssistToolResult {
        var finalData = data ?? [:]
        if let diff = diff, finalData[AssistToolDataKey.diff] == nil {
            finalData[AssistToolDataKey.diff] = diff
        }
        return AssistToolResult(
            success: true,
            output: output,
            data: finalData.isEmpty ? nil : finalData,
            error: nil,
            diagnostics: diagnostics,
            filesChanged: filesChanged,
            diff: diff,
            duration: duration,
            suggestedNextActions: suggestedNextActions
        )
    }

    public static func failure(
        _ error: String,
        code: AssistToolErrorCode? = nil,
        diagnostics: [String] = [],
        suggestedNextActions: [String] = []
    ) -> AssistToolResult {
        var result = AssistToolResult(
            success: false,
            output: "Error: \(error)",
            error: error,
            diagnostics: diagnostics,
            suggestedNextActions: suggestedNextActions,
            toolErrorCode: code
        )
        return result
    }
}

// MARK: - Protocols for Context

public protocol AssistMemoryGraphProtocol: Sendable {
    func store(key: String, value: String) async
    func retrieve(key: String) async -> String?
    func clear() async
}

public actor DefaultAssistMemoryGraph: AssistMemoryGraphProtocol {
    private var storage: [String: String] = [:]

    public init() {}

    public func store(key: String, value: String) async {
        storage[key] = value
    }

    public func retrieve(key: String) async -> String? {
        storage[key]
    }

    public func clear() async {
        storage.removeAll()
    }
}

public protocol AssistLoggerProtocol: Sendable {
    func info(_ message: String, toolId: String?) async
    func warning(_ message: String, toolId: String?) async
    func error(_ message: String, toolId: String?) async
    func debug(_ message: String, toolId: String?) async
}

public extension AssistLoggerProtocol {
    func info(_ message: String) async { await info(message, toolId: nil) }
    func warning(_ message: String) async { await warning(message, toolId: nil) }
    func error(_ message: String) async { await error(message, toolId: nil) }
    func debug(_ message: String) async { await debug(message, toolId: nil) }
}

public final class DefaultAssistLogger: AssistLoggerProtocol, Sendable {
    public init() {}
    public func info(_ message: String, toolId: String?) async {}
    public func warning(_ message: String, toolId: String?) async {}
    public func error(_ message: String, toolId: String?) async {}
    public func debug(_ message: String, toolId: String?) async {}
}

public protocol AssistFileSystemProtocol: Sendable {
    func readFile(at path: String) throws -> String
    func writeFile(at path: String, content: String) throws
    func deleteFile(at path: String) throws
    func deleteDirectory(at path: String) throws
    func moveFile(from: String, to: String) throws
    func copyFile(from: String, to: String) throws
    func exists(at path: String) -> Bool
    func appendFile(at path: String, content: String) throws
    func listDirectory(at path: String) throws -> [String]
    func createDirectory(at path: String) throws
    func resolve(_ path: String) throws -> URL
    var currentDirectory: URL { get }
    func setCurrentDirectory(_ path: String) throws -> URL
}

public final class AssistFileSystem: AssistFileSystemProtocol, @unchecked Sendable {
    private let fileManager = FileManager.default
    private let workspaceRoot: URL
    private let lock = NSLock()
    private var _currentDirectory: URL

    public var currentDirectory: URL {
        lock.withLock { _currentDirectory }
    }

    public init(workspaceRoot: URL) {
        self.workspaceRoot = workspaceRoot
        self._currentDirectory = workspaceRoot
    }

    public func restoreCurrentDirectory(_ url: URL) throws {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let root = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path == root.path || resolved.path.hasPrefix(root.path + "/") else {
            throw NSError(domain: "PathSecurityError", code: 403, userInfo: [NSLocalizedDescriptionKey: "Security Error: Stored working directory is outside workspace bounds: \(url.path)"])
        }
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue else {
            throw NSError(domain: "PathSecurityError", code: 404, userInfo: [NSLocalizedDescriptionKey: "Stored working directory does not exist or is not a directory: \(url.path)"])
        }
        lock.withLock { _currentDirectory = resolved }
    }

    public func setCurrentDirectory(_ path: String) throws -> URL {
        let target = try resolve(path)
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue else {
            throw NSError(domain: "PathSecurityError", code: 404, userInfo: [NSLocalizedDescriptionKey: "Directory does not exist or is not a directory: \(path)"])
        }
        lock.withLock { _currentDirectory = target }
        return target
    }

    public func readFile(at path: String) throws -> String {
        let url = try resolve(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    public func writeFile(at path: String, content: String) throws {
        let url = try resolve(path)
        let parentDir = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDir.path) {
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    public func deleteFile(at path: String) throws {
        let url = try resolve(path)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    public func deleteDirectory(at path: String) throws {
        let url = try resolve(path)
        let root = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard url.path != root.path else {
            throw NSError(domain: "PathSecurityError", code: 403, userInfo: [NSLocalizedDescriptionKey: "Security Error: Refusing to delete the workspace root itself: \(path)"])
        }
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw NSError(domain: "PathSecurityError", code: 404, userInfo: [NSLocalizedDescriptionKey: "No directory at \(path) — nothing to delete."])
        }
        try fileManager.removeItem(at: url)
    }

    public func moveFile(from: String, to: String) throws {
        let fromURL = try resolve(from)
        let toURL = try resolve(to)
        guard !fileManager.fileExists(atPath: toURL.path) else {
            throw NSError(domain: "PathSecurityError", code: 409, userInfo: [NSLocalizedDescriptionKey: "Destination already exists: \(to). Delete it first or choose another destination."])
        }
        try fileManager.moveItem(at: fromURL, to: toURL)
    }

    public func copyFile(from: String, to: String) throws {
        let fromURL = try resolve(from)
        let toURL = try resolve(to)
        guard !fileManager.fileExists(atPath: toURL.path) else {
            throw NSError(domain: "PathSecurityError", code: 409, userInfo: [NSLocalizedDescriptionKey: "Destination already exists: \(to). Delete it first or choose another destination."])
        }
        try fileManager.copyItem(at: fromURL, to: toURL)
    }

    public func exists(at path: String) -> Bool {
        guard let url = try? resolve(path) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    public func appendFile(at path: String, content: String) throws {
        let url = try resolve(path)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try writeFile(at: path, content: existing + content)
    }

    public func createDirectory(at path: String) throws {
        let url = try resolve(path)
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    public func resolve(_ path: String) throws -> URL {
        if path == "/tmp/swiftcode/scripts" || path.hasPrefix("/tmp/swiftcode/scripts/") {
            return URL(fileURLWithPath: path).standardized
        }
        guard workspaceRoot.path != "/" else {
            throw NSError(domain: "PathSecurityError", code: 403, userInfo: [NSLocalizedDescriptionKey: "No active project: workspace root is unavailable."])
        }

        let base: URL
        let normalizedPath: String
        if path == workspaceRoot.path || path.hasPrefix(workspaceRoot.path + "/") {
            base = workspaceRoot
            normalizedPath = String(path.dropFirst(workspaceRoot.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else if path.hasPrefix("/") {
            base = workspaceRoot
            normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            base = currentDirectory
            normalizedPath = path
        }
        let root = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
        var probe = base.appendingPathComponent(normalizedPath).standardized
        var suffix: [String] = []
        while !fileManager.fileExists(atPath: probe.path) && probe.path != root.path && probe.path != base.standardized.path {
            suffix.insert(probe.lastPathComponent, at: 0)
            probe = probe.deletingLastPathComponent()
        }
        var resolvedURL = probe.resolvingSymlinksInPath()
        for component in suffix { resolvedURL.appendPathComponent(component) }
        resolvedURL = resolvedURL.standardized
        guard resolvedURL.path == root.path || resolvedURL.path.hasPrefix(root.path + "/") else {
            throw NSError(domain: "PathSecurityError", code: 403, userInfo: [NSLocalizedDescriptionKey: "Security Error: Path traversal outside workspace bounds is forbidden: \(path)"])
        }
        return resolvedURL
    }

    public func listDirectory(at path: String) throws -> [String] {
        let url = try resolve(path)
        return try fileManager.contentsOfDirectory(atPath: url.path)
    }
}

public protocol AssistGitManagerProtocol: Sendable {
    func status() throws -> String
    func commit(message: String) throws
    func push() async throws
}

public final class DefaultAssistGitManager: AssistGitManagerProtocol, Sendable {
    public init() {}
    public func status() throws -> String { "Clean working directory (git shim)" }
    public func commit(message: String) throws {}
    public func push() async throws {}
}

public protocol AssistPermissionsManagerProtocol: Sendable {
    func isPathAllowed(_ path: String) -> Bool
    func authorizeOperation(_ operation: String) -> Bool
}

public final class DefaultAssistPermissionsManager: AssistPermissionsManagerProtocol, Sendable {
    public init() {}
    public func isPathAllowed(_ path: String) -> Bool { true }
    public func authorizeOperation(_ operation: String) -> Bool { true }
}

public struct AssistContext: Sendable {
    public let sessionId: UUID
    public let project: Any?
    public let workspaceRoot: URL
    public let memory: any AssistMemoryGraphProtocol
    public let logger: any AssistLoggerProtocol
    public let fileSystem: any AssistFileSystemProtocol
    public let git: any AssistGitManagerProtocol
    public let permissions: any AssistPermissionsManagerProtocol
    public let safetyLevel: AssistSafetyLevel
    public let isAutonomous: Bool
    public let sessionExecutionMode: ExecutionMode

    public init(
        sessionId: UUID = UUID(),
        project: Any? = nil,
        workspaceRoot: URL = URL.documentsDirectory,
        memory: (any AssistMemoryGraphProtocol)? = nil,
        logger: (any AssistLoggerProtocol)? = nil,
        fileSystem: (any AssistFileSystemProtocol)? = nil,
        git: (any AssistGitManagerProtocol)? = nil,
        permissions: (any AssistPermissionsManagerProtocol)? = nil,
        safetyLevel: AssistSafetyLevel = .balanced,
        isAutonomous: Bool = true,
        sessionExecutionMode: ExecutionMode = .autopilot
    ) {
        self.sessionId = sessionId
        self.project = project
        self.workspaceRoot = workspaceRoot
        self.memory = memory ?? DefaultAssistMemoryGraph()
        self.logger = logger ?? DefaultAssistLogger()
        self.fileSystem = fileSystem ?? AssistFileSystem(workspaceRoot: workspaceRoot)
        self.git = git ?? DefaultAssistGitManager()
        self.permissions = permissions ?? DefaultAssistPermissionsManager()
        self.safetyLevel = safetyLevel
        self.isAutonomous = isAutonomous
        self.sessionExecutionMode = sessionExecutionMode
    }
}

// MARK: - AssistTool Protocol

public protocol AssistTool: Sendable {
    var id: String { get }
    var name: String { get }
    var description: String { get }
    var parametersSchema: JSONSchema { get }
    var capability: ToolCapability { get }
    var riskLevel: ToolRiskLevel { get }
    var isReadOnly: Bool { get }
    var isMutating: Bool { get }
    var prerequisites: [String] { get }
    var estimatedCost: Double { get }

    var outputFormat: ToolOutputFormat { get }
    var requiredPermission: ToolPermissionRequirement { get }
    var supportedOperations: [String] { get }
    var knownLimitations: [String] { get }
    var canChainResult: Bool { get }
    var isDestructive: Bool { get }
    var resourceScope: String { get }

    func execute(input: [String: Any], context: AssistContext) async throws -> AssistToolResult
}

public extension AssistTool {
    var parametersSchema: JSONSchema {
        JSONSchema(type: "object", description: description, properties: [:], required: [])
    }

    var capability: ToolCapability {
        .general
    }

    var riskLevel: ToolRiskLevel {
        .safeRead
    }

    var isReadOnly: Bool {
        riskLevel == .safeRead
    }

    var isMutating: Bool {
        riskLevel == .safeMutation || riskLevel == .potentiallyDestructive
    }

    var isDestructive: Bool {
        riskLevel == .potentiallyDestructive
    }

    var prerequisites: [String] {
        []
    }

    var estimatedCost: Double {
        0.01
    }

    var outputFormat: ToolOutputFormat {
        if isMutating { return .file }
        return .text
    }

    var requiredPermission: ToolPermissionRequirement {
        if isMutating { return .fileSystem }
        return .none
    }

    var supportedOperations: [String] {
        []
    }

    var knownLimitations: [String] {
        []
    }

    var canChainResult: Bool {
        true
    }

    var resourceScope: String {
        "Workspace Project"
    }
}

// MARK: - Workspace & Process Helpers

public enum AssistWorkspacePaths {
    public static func root(for context: AssistContext) -> URL {
        context.workspaceRoot
    }

    public static func resolve(_ raw: String, workspaceRoot: URL) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0"), !trimmed.hasPrefix("~"), !trimmed.contains("..") else {
            return nil
        }
        let rootPath = workspaceRoot.standardized.path
        let candidate: URL
        if trimmed.hasPrefix("/") {
            candidate = URL(fileURLWithPath: trimmed).standardized
        } else {
            candidate = workspaceRoot.appendingPathComponent(trimmed).standardized
        }
        let candidatePath = candidate.path
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            return nil
        }
        return candidate
    }

    public static func relative(_ url: URL, workspaceRoot: URL) -> String {
        let rootPath = workspaceRoot.standardized.path
        let path = url.standardized.path
        if path == rootPath { return "." }
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return path
    }

    public static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}

public enum AssistWorkspaceScan {
    public static let skippedDirs: Set<String> = [
        ".git", ".build", "build", "DerivedData", ".swiftpm",
        "Pods", "Carthage", "node_modules", ".venv"
    ]
    public static let sourceExts: Set<String> = ["swift", "m", "mm", "h", "c", "cpp", "hpp"]

    public static func scan(root: URL, query: String) -> [String] {
        let files = AssistToolingSupport.enumeratedFiles(at: root)
        let needle = query.lowercased()
        var results: [String] = []
        for file in files {
            if file.lastPathComponent.lowercased().contains(needle) {
                results.append(AssistToolingSupport.relativePath(for: file, workspaceRoot: root))
            }
        }
        return results
    }

    public static func files(under root: URL, extensions: Set<String>? = nil, maxFiles: Int = 20000) -> [URL] {
        var results: [URL] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return results
        }
        let rootPath = root.standardized.path
        while let url = enumerator.nextObject() as? URL, results.count < maxFiles {
            let rel = url.standardized.path.replacingOccurrences(of: rootPath + "/", with: "")
            if skippedDirs.contains(rel.split(separator: "/").first.map(String.init) ?? "") { continue }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir { continue }
            if let exts = extensions, !exts.contains(url.pathExtension.lowercased()) { continue }
            results.append(url)
        }
        return results
    }

    public static func swiftFiles(under root: URL, maxFiles: Int = 8000) -> [URL] {
        files(under: root, extensions: ["swift"], maxFiles: maxFiles)
    }

    public static func readLines(_ url: URL) -> [String]? {
        (try? String(contentsOf: url, encoding: .utf8))?.components(separatedBy: .newlines)
    }

    public static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    public static func fileSize(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    public static func declaredFuncName(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("func ") || t.contains(" func ") else { return nil }
        guard let r = t.range(of: "func ") else { return nil }
        let rest = String(t[r.upperBound...])
        let name = rest.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).first.map(String.init) ?? ""
        return name.isEmpty ? nil : name
    }

    public static func findPbxproj(in root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return nil
        }
        return enumerator.compactMap { $0 as? URL }.first { $0.pathExtension == "pbxproj" }
    }
}

public enum AssistTextFormat {
    public static func truncated(_ text: String, limit: Int, label: String = "truncated") -> (String, Bool) {
        guard text.count > limit else { return (text, false) }
        let prefix = String(text.prefix(limit))
        return (prefix + "\n… [\(label): showing first \(limit) of \(text.count) characters]", true)
    }

    public static func markdownTable(headers: [String], rows: [[String]]) -> String {
        var lines: [String] = []
        lines.append("| " + headers.joined(separator: " | ") + " |")
        lines.append("| " + headers.map { _ in "---" }.joined(separator: " | ") + " |")
        for row in rows {
            let cells = (0..<headers.count).map { i in
                i < row.count ? row[i].replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") : ""
            }
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }
}

public enum AssistArtifactNaming {
    public static func normalize(_ raw: String) -> String? {
        var stem = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !stem.isEmpty, !stem.contains("\0") else { return nil }
        guard !stem.contains("/") && !stem.contains("\\") && !stem.contains("..") else { return nil }
        if stem.hasSuffix(".md") {
            stem = String(stem.dropLast(3))
        } else if stem.hasSuffix(".markdown") {
            stem = String(stem.dropLast(9))
        }
        stem = stem.replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
        while stem.contains("__") { stem = stem.replacingOccurrences(of: "__", with: "_") }
        stem = stem.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        guard !stem.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")
        guard stem.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        guard stem.count <= 120 else { return nil }
        return stem + ".md"
    }

    public static func displayTitle(for filename: String) -> String {
        var stem = filename
        for ext in [".md", ".markdown", ".png", ".mov", ".mp4", ".jpg", ".jpeg"] {
            if stem.lowercased().hasSuffix(ext) {
                stem = String(stem.dropLast(ext.count))
                break
            }
        }
        let words = stem.split(separator: "_").map { part -> String in
            guard let first = part.first else { return "" }
            return String(first).uppercased() + part.dropFirst()
        }.filter { !$0.isEmpty }
        let title = words.joined(separator: " ")
        return title.isEmpty ? filename : title
    }
}

public enum AssistToolingSupport {
    public static func resolvePath(_ path: String?, workspaceRoot: URL) -> URL {
        let rawPath = (path?.isEmpty == false ? path! : ".")
        if rawPath == "." { return workspaceRoot }
        let root = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = workspaceRoot.appendingPathComponent(rawPath).standardized
        guard resolved.path == root.path || resolved.path.hasPrefix(root.path + "/") else {
            return workspaceRoot
        }
        return resolved
    }

    public static func relativePath(for url: URL, workspaceRoot: URL) -> String {
        let root = workspaceRoot.path
        if url.path.hasPrefix(root + "/") {
            return String(url.path.dropFirst(root.count + 1))
        }
        return url.lastPathComponent
    }

    public static func enumeratedFiles(at root: URL, allowedExtensions: Set<String>? = nil, maxFileSize: Int = 500_000) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else {
            return []
        }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else {
                continue
            }
            if let size = values.fileSize, size > maxFileSize { continue }
            if let allowedExt = allowedExtensions, !allowedExt.contains(fileURL.pathExtension.lowercased()) {
                continue
            }
            files.append(fileURL)
        }
        return files
    }

    public static func isCodeFile(_ fileURL: URL) -> Bool {
        let codeExtensions: Set<String> = ["swift", "m", "mm", "h", "hpp", "c", "cpp", "js", "ts", "tsx", "jsx", "py", "rb", "java", "kt", "go", "rs"]
        return codeExtensions.contains(fileURL.pathExtension.lowercased())
    }

    public static func readText(_ url: URL) -> String? {
        return try? String(contentsOf: url, encoding: .utf8)
    }

    public static func keywordOccurrences(in content: String, keywords: [String]) -> Int {
        keywords.reduce(0) { partial, keyword in
            partial + content.components(separatedBy: keyword).count - 1
        }
    }

    public static func runProcess(executablePath: String, arguments: [String], workingDirectory: URL?) -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let workingDirectory = workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        nonisolated final class Accumulator: @unchecked Sendable {
            private let lock = NSLock()
            private var content = ""
            nonisolated func append(_ string: String) {
                lock.withLock { content += string }
            }
            nonisolated var text: String {
                lock.withLock { content }
            }
        }

        let outAccumulator = Accumulator()
        let errAccumulator = Accumulator()

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) {
                outAccumulator.append(text)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) {
                errAccumulator.append(text)
            }
        }
        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return (-1, "", "Failed to launch \(executablePath): \(error.localizedDescription)")
        }
        process.waitUntilExit()
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        let outRemainder = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errRemainder = errPipe.fileHandleForReading.readDataToEndOfFile()
        if let remainder = String(data: outRemainder, encoding: .utf8), !remainder.isEmpty {
            outAccumulator.append(remainder)
        }
        if let remainder = String(data: errRemainder, encoding: .utf8), !remainder.isEmpty {
            errAccumulator.append(remainder)
        }
        return (process.terminationStatus, outAccumulator.text, errAccumulator.text)
    }
}

public enum AssistArgvRunner {
    public struct Result: Sendable {
        public let exitCode: Int32
        public let output: String
        public let timedOut: Bool

        public init(exitCode: Int32, output: String, timedOut: Bool) {
            self.exitCode = exitCode
            self.output = output
            self.timedOut = timedOut
        }
    }

    public static func run(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL,
        timeout: TimeInterval = 120
    ) throws -> Result {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        let waitResult = semaphore.wait(timeout: .now() + timeout)
        var timedOut = false
        if waitResult == .timedOut {
            timedOut = true
            process.terminate()
            if semaphore.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = semaphore.wait(timeout: .now() + 2)
            }
        }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Result(exitCode: process.terminationStatus, output: output, timedOut: timedOut)
    }
}

// MARK: - Search & Code Helpers

public struct AssistSearchFunctions {
    public static func searchText(in directory: URL, pattern: String, isRegex: Bool) throws -> [URL: [String]] {
        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles])

        var results: [URL: [String]] = [:]

        while let fileURL = enumerator?.nextObject() as? URL {
            let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard resourceValues?.isRegularFile == true else { continue }

            if let fileSize = resourceValues?.fileSize, fileSize > 1_000_000 {
                continue
            }

            let binaryExtensions = ["png", "jpg", "jpeg", "gif", "pdf", "zip", "exe", "dylib", "a"]
            if binaryExtensions.contains(fileURL.pathExtension.lowercased()) {
                continue
            }

            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let lines = content.components(separatedBy: .newlines)
            var matches: [String] = []

            if isRegex {
                let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
                for (index, line) in lines.enumerated() {
                    let range = NSRange(location: 0, length: line.utf16.count)
                    if regex.firstMatch(in: line, options: [], range: range) != nil {
                        matches.append("\(index + 1): \(line)")
                    }
                }
            } else {
                for (index, line) in lines.enumerated() {
                    if line.localizedCaseInsensitiveContains(pattern) {
                        matches.append("\(index + 1): \(line)")
                    }
                }
            }

            if !matches.isEmpty {
                results[fileURL] = matches
            }
        }

        return results
    }
}

public struct AssistCodeFunctions {
    public static func replaceBlock(in content: String, search: String, replace: String) -> String {
        return content.replacingOccurrences(of: search, with: replace)
    }

    public static func insertAfter(in content: String, pattern: String, insert: String) -> String {
        if let range = content.range(of: pattern) {
            var newContent = content
            newContent.insert(contentsOf: "\n" + insert, at: range.upperBound)
            return newContent
        }
        return content
    }

    public static func insertBefore(in content: String, pattern: String, insert: String) -> String {
        if let range = content.range(of: pattern) {
            var newContent = content
            newContent.insert(contentsOf: insert + "\n", at: range.lowerBound)
            return newContent
        }
        return content
    }
}

// MARK: - Diff & Mutation Shims

public struct DiffHunk: Codable, Sendable, Identifiable {
    public let id: UUID
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    public let lines: [String]

    public init(id: UUID = UUID(), oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, lines: [String]) {
        self.id = id
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
    }

    public var header: String {
        return "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
    }
}

public struct UnifiedDiffResult: Codable, Sendable {
    public let filePath: String
    public let hunks: [DiffHunk]
    public let addedLines: Int
    public let removedLines: Int
    public let unifiedText: String

    public var hasChanges: Bool {
        return addedLines > 0 || removedLines > 0
    }

    public init(filePath: String, hunks: [DiffHunk], addedLines: Int, removedLines: Int, unifiedText: String) {
        self.filePath = filePath
        self.hunks = hunks
        self.addedLines = addedLines
        self.removedLines = removedLines
        self.unifiedText = unifiedText
    }
}

public enum DiffConflictError: Error, LocalizedError, Sendable {
    case targetNotFound(target: String, file: String)
    case multipleMatches(target: String, count: Int, file: String)
    case staleFileState(file: String)

    public var errorDescription: String? {
        switch self {
        case .targetNotFound(let target, let file):
            let preview = target.count > 60 ? String(target.prefix(60)) + "..." : target
            return "Target text '\(preview)' was not found in \(file)."
        case .multipleMatches(let target, let count, let file):
            let preview = target.count > 60 ? String(target.prefix(60)) + "..." : target
            return "Target text '\(preview)' matched \(count) locations in \(file)."
        case .staleFileState(let file):
            return "File \(file) state changed unexpectedly on disk."
        }
    }
}

public struct FileActivityItem: Sendable {
    public let filePath: String
    public let operation: String
    public let addedLines: Int
    public let deletedLines: Int
    public let diffSummary: String
    public let diffHunks: [String]
    public let isReconciled: Bool

    public init(filePath: String, operation: String, addedLines: Int, deletedLines: Int, diffSummary: String, diffHunks: [String], isReconciled: Bool) {
        self.filePath = filePath
        self.operation = operation
        self.addedLines = addedLines
        self.deletedLines = deletedLines
        self.diffSummary = diffSummary
        self.diffHunks = diffHunks
        self.isReconciled = isReconciled
    }
}

public final class AssistDiffEngine: Sendable {
    public static let shared = AssistDiffEngine()
    public init() {}

    public func createUnifiedDiff(filePath: String, oldContent: String, newContent: String) -> UnifiedDiffResult {
        let origLines = oldContent.components(separatedBy: .newlines)
        let modLines = newContent.components(separatedBy: .newlines)
        let diff = generateUnifiedDiff(filePath: filePath, original: oldContent, modified: newContent)
        let hunk = DiffHunk(oldStart: 1, oldCount: origLines.count, newStart: 1, newCount: modLines.count, lines: [])
        return UnifiedDiffResult(
            filePath: filePath,
            hunks: [hunk],
            addedLines: max(0, modLines.count - origLines.count),
            removedLines: max(0, origLines.count - modLines.count),
            unifiedText: diff
        )
    }

    public func generateUnifiedDiff(filePath: String, original: String, modified: String) -> String {
        let origLines = original.components(separatedBy: .newlines)
        let modLines = modified.components(separatedBy: .newlines)
        var diff = "--- a/\(filePath)\n+++ b/\(filePath)\n@@ -1,\(origLines.count) +1,\(modLines.count) @@\n"
        for l in origLines {
            diff += "-\(l)\n"
        }
        for l in modLines {
            diff += "+\(l)\n"
        }
        return diff
    }

    public func applyTargetedReplacement(
        filePath: String,
        originalContent: String,
        targetContent: String,
        replacementContent: String
    ) throws -> (modifiedContent: String, diffResult: UnifiedDiffResult) {
        let occurrences = originalContent.components(separatedBy: targetContent).count - 1

        if occurrences == 0 {
            throw DiffConflictError.targetNotFound(target: targetContent, file: filePath)
        }
        if occurrences > 1 {
            throw DiffConflictError.multipleMatches(target: targetContent, count: occurrences, file: filePath)
        }

        let modified = originalContent.replacingOccurrences(of: targetContent, with: replacementContent)
        let diff = createUnifiedDiff(filePath: filePath, oldContent: originalContent, newContent: modified)
        return (modified, diff)
    }

    public func applyTargetedReplacement(
        source: String,
        target: String,
        replacement: String,
        allowMultiple: Bool = false,
        filePath: String = "file"
    ) throws -> String {
        let occurrences = source.components(separatedBy: target).count - 1

        if occurrences == 0 {
            throw DiffConflictError.targetNotFound(target: target, file: filePath)
        }
        if occurrences > 1 && !allowMultiple {
            throw DiffConflictError.multipleMatches(target: target, count: occurrences, file: filePath)
        }

        return source.replacingOccurrences(of: target, with: replacement)
    }
}

public enum LiveEditOperationType: String, Codable, Sendable {
    case replace, create, delete, append, insert, write
}

public struct LiveFileEditEvent: Sendable {
    public let sessionId: String
    public let taskId: String
    public let goalId: String
    public let filePath: String
    public let operationId: String
    public let operationType: LiveEditOperationType
    public let sequenceNumber: Int
    public let beforeContent: String
}

public final class LiveDiffStreamer: @unchecked Sendable {
    public static let shared = LiveDiffStreamer()
    public var activeStreams: [String: LiveFileEditEvent] = [:]
    public var recentEdits: [LiveFileEditEvent] = []

    public init() {}

    @discardableResult
    public func beginEdit(
        sessionId: String = UUID().uuidString,
        taskId: String = "active_task",
        goalId: String = "active_goal",
        filePath: String,
        operationType: LiveEditOperationType,
        beforeContent: String
    ) -> String {
        let opId = UUID().uuidString
        let event = LiveFileEditEvent(
            sessionId: sessionId,
            taskId: taskId,
            goalId: goalId,
            filePath: filePath,
            operationId: opId,
            operationType: operationType,
            sequenceNumber: recentEdits.count + 1,
            beforeContent: beforeContent
        )
        activeStreams[filePath] = event
        recentEdits.append(event)
        return opId
    }

    public func streamMutation(filePath: String, currentContent: String, isFinal: Bool) {}
    public func completeEdit(filePath: String, finalContent: String) {
        activeStreams.removeValue(forKey: filePath)
    }
    public func cancelStream(filePath: String) {
        activeStreams.removeValue(forKey: filePath)
    }
    public func reconcileWithDisk(filePath: String, actualDiskContent: String) {}
    public func clearAll() {
        activeStreams.removeAll()
        recentEdits.removeAll()
    }
}

@MainActor
public final class ProjectSessionStore {
    public static let shared = ProjectSessionStore()
    public init() {}

    public func recordAssistFileMutation(
        path: String,
        beforeContent: String,
        afterContent: String,
        addedLines: Int,
        deletedLines: Int
    ) {}
}

public final class XcodeProjWriter: Sendable {
    public static let shared = XcodeProjWriter()
    public init() {}

    @discardableResult
    public func addFileReference(filePath: String, projectURL: URL) throws -> Bool {
        true
    }
}

@MainActor
public final class AssistManager {
    public static let shared = AssistManager()
    public var lastAssistantMessage: String = ""
    public init() {}

    public func updateLastAssistantMessageContent(_ content: String) {
        lastAssistantMessage = content
    }
}

public final class AssistWorkingDirectoryStore: @unchecked Sendable {
    public static let shared = AssistWorkingDirectoryStore()
    private let lock = NSLock()
    private var directories: [UUID: URL] = [:]

    public init() {}

    public func currentDirectory(for sessionId: UUID) -> URL? {
        lock.withLock { directories[sessionId] }
    }

    public func setCurrentDirectory(_ directory: URL, for sessionId: UUID) {
        lock.withLock { directories[sessionId] = directory }
    }

    public func remove(for sessionId: UUID) {
        lock.withLock { directories.removeValue(forKey: sessionId) }
    }
}

// MARK: - AssistTool Registry

public enum ToolHealthStatus: String, Codable, Sendable {
    case registered
    case available
    case temporarilyUnavailable
    case disabled
    case error
}

public struct ToolHealth: Codable, Sendable {
    public let toolId: String
    public var status: ToolHealthStatus
    public var lastError: String?
    public let registeredAt: Date
    public var lastUsedAt: Date?
    public var useCount: Int

    public init(toolId: String, status: ToolHealthStatus = .registered, lastError: String? = nil) {
        self.toolId = toolId
        self.status = status
        self.lastError = lastError
        self.registeredAt = Date()
        self.lastUsedAt = nil
        self.useCount = 0
    }
}

@MainActor
public final class AssistToolRegistry {
    public static let shared = AssistToolRegistry()

    private var tools: [String: any AssistTool] = [:]
    private var health: [String: ToolHealth] = [:]
    private var capabilityIndex: [ToolCapability: [String]] = [:]

    public init() {}

    public func register(_ tool: any AssistTool) {
        tools[tool.id] = tool
        health[tool.id] = ToolHealth(toolId: tool.id)
        capabilityIndex[tool.capability, default: []].append(tool.id)
    }

    public func getTool(_ id: String) -> (any AssistTool)? {
        tools[id]
    }

    public var allTools: [any AssistTool] {
        Array(tools.values)
    }

    public func toolsForCapability(_ capability: ToolCapability) -> [any AssistTool] {
        let ids = capabilityIndex[capability] ?? []
        return ids.compactMap { tools[$0] }
    }
}
