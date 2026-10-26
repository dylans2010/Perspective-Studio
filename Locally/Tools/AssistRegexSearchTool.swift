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
                "pattern": JSONSchema(type: "string", description: "Regular expression pattern to search for.")
            ],
            required: ["pattern"]
        )
    }

    public func execute(input: [String: Any], context: AssistContext) async throws -> AssistToolResult {
        guard let pattern = input["pattern"] as? String else {
            return .failure("Missing required parameter: pattern")
        }

        do {
            let results = try AssistSearchFunctions.searchText(in: context.workspaceRoot, pattern: pattern, isRegex: true)
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
            return .success(output, data: ["results": matchText])
        } catch {
            return .failure("Regex search failed: \(error.localizedDescription)")
        }
    }
}
