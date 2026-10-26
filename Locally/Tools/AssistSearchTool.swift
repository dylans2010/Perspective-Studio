import Foundation

public struct AssistSearchTool: AssistTool {
    public let id = "search_text"
    public let name = "Search Text"
    public let description = "Searches for text across files in the project sandbox."

    public init() {}

    public var capability: ToolCapability { .repositoryDiscovery }
    public var riskLevel: ToolRiskLevel { .safeRead }

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: "Searches for literal text across files in the project sandbox.",
            properties: [
                "pattern": JSONSchema(type: "string", description: "Literal text pattern to find."),
                "path": JSONSchema(type: "string", description: "Optional workspace-relative directory to search in (default: '.')."),
                "fileExtension": JSONSchema(type: "string", description: "Optional file extension filter (e.g. 'swift', 'json')."),
                "maxResults": JSONSchema(type: "integer", description: "Maximum number of matched lines to return (default: 50)."),
                "includeIgnored": JSONSchema(type: "boolean", description: "Whether to search in build/cache directories (default: false).")
            ],
            required: ["pattern"]
        )
    }

    public func execute(input: [String: Any], context: AssistContext) async throws -> AssistToolResult {
        guard let pattern = (input["pattern"] ?? input["query"]) as? String,
              !pattern.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .failure("Missing required parameter: pattern", code: .missingArgument)
        }

        let pathArg = (input["path"] as? String) ?? "."
        let searchDir: URL
        do {
            searchDir = try context.fileSystem.resolve(pathArg)
        } catch {
            return .failure("Invalid search path '\(pathArg)': \(error.localizedDescription)", code: .invalidInput)
        }

        let rawExt = (input["fileExtension"] ?? input["extension"] ?? input["ext"]) as? String
        let fileExtension = rawExt?.trimmingCharacters(in: CharacterSet(charactersIn: ". \t\n\r"))
        let maxResults: Int
        if let rawMax = input["maxResults"] as? Int {
            maxResults = max(1, min(rawMax, 200))
        } else if let rawMaxD = input["maxResults"] as? Double {
            maxResults = max(1, min(Int(rawMaxD), 200))
        } else {
            maxResults = 50
        }
        let includeIgnored = (input["includeIgnored"] as? Bool) ?? false

        do {
            let results = try AssistSearchFunctions.searchText(
                in: searchDir,
                pattern: pattern,
                isRegex: false,
                fileExtension: fileExtension,
                maxResults: maxResults,
                includeIgnored: includeIgnored
            )

            let formattedResults = results.sorted(by: { $0.key.path < $1.key.path }).map { (url, matches) in
                let relativePath = AssistToolingSupport.relativePath(for: url, workspaceRoot: context.workspaceRoot)
                return "\(relativePath):\n" + matches.joined(separator: "\n")
            }.joined(separator: "\n\n")

            let output: String
            if formattedResults.isEmpty {
                output = "Search results for '\(pattern)': No matches found."
            } else {
                output = """
                Search results for '\(pattern)':
                \(formattedResults)
                """
            }
            return .success(output, data: [
                "results": formattedResults,
                "count": "\(results.values.reduce(0, { $0 + $1.count }))",
                "filesCount": "\(results.count)"
            ])
        } catch {
            return .failure("Search failed: \(error.localizedDescription)", code: .executionFailed)
        }
    }
}
