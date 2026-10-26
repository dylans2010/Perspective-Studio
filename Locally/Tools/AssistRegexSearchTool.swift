import Foundation

public struct AssistRegexSearchTool: AssistTool {
    public let id = "search_regex"
    public let name = "Regex Search"
    public let description = "Searches for a regular expression pattern within the project files."

    public init() {}

    public var capability: ToolCapability { .repositoryDiscovery }
    public var riskLevel: ToolRiskLevel { .safeRead }

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: "Searches for a regular expression pattern within project files.",
            properties: [
                "pattern": JSONSchema(type: "string", description: "Regular expression pattern to search for."),
                "path": JSONSchema(type: "string", description: "Optional workspace-relative directory to search in (default: '.')."),
                "fileExtension": JSONSchema(type: "string", description: "Optional file extension filter (e.g. 'swift', 'json')."),
                "maxResults": JSONSchema(type: "integer", description: "Maximum number of matched lines to return (default: 50)."),
                "includeIgnored": JSONSchema(type: "boolean", description: "Whether to search in build/cache directories (default: false).")
            ],
            required: ["pattern"]
        )
    }

    public func execute(input: [String: Any], context: AssistContext) async throws -> AssistToolResult {
        guard let pattern = (input["pattern"] ?? input["regex"]) as? String,
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
                isRegex: true,
                fileExtension: fileExtension,
                maxResults: maxResults,
                includeIgnored: includeIgnored
            )

            let lines = results.sorted(by: { $0.key.path < $1.key.path }).flatMap { url, matches in
                let rel = AssistToolingSupport.relativePath(for: url, workspaceRoot: context.workspaceRoot)
                return matches.map { "\(rel):\($0)" }
            }
            let matchText = lines.joined(separator: "\n")
            let output: String
            if lines.isEmpty {
                output = "Regex search completed for '\(pattern)': No matches found."
            } else {
                output = """
                Regex search results for '\(pattern)':
                \(matchText)
                """
            }
            return .success(output, data: [
                "results": matchText,
                "count": "\(lines.count)",
                "filesCount": "\(results.count)"
            ])
        } catch {
            return .failure("Regex search failed: \(error.localizedDescription)", code: .executionFailed)
        }
    }
}
