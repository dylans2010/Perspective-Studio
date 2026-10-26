import Foundation

public struct AssistTreeViewTool: AssistTool {
    public let id = "tree_view"
    public let name = "Tree View"
    public let description = "Generates a tree-like representation of the project structure."

    public init() {}

    public var capability: ToolCapability { .repositoryDiscovery }
    public var riskLevel: ToolRiskLevel { .safeRead }

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: "Generates a tree-like representation of the project structure. Symlinks are listed as leaves, never followed (prevents symlink-cycle recursion). Output is capped; a truncation marker is appended when the cap is hit.",
            properties: [
                "path": JSONSchema(type: "string", description: "Workspace-relative path to render. Default: \".\" (workspace root)."),
                "maxDepth": JSONSchema(type: "integer", description: "Maximum tree depth. Clamped to 1...10. Default: 3."),
                "showHidden": JSONSchema(type: "boolean", description: "Whether to include hidden files and directories (default: false)."),
                "includeIgnored": JSONSchema(type: "boolean", description: "Whether to include build/cache directories such as .git, build, DerivedData (default: false).")
            ],
            required: []
        )
    }

    public func execute(input: [String: Any], context: AssistContext) async throws -> AssistToolResult {
        var maxDepth = 3
        if let raw = input["maxDepth"] {
            guard let parsed = Self.parseDepth(raw) else {
                return .failure("Invalid maxDepth: must be an integer >= 1 (got '\(raw)').", code: .invalidInput)
            }
            maxDepth = min(max(parsed, 1), 10)
        }
        let showHidden = (input["showHidden"] as? Bool) ?? false
        let includeIgnored = (input["includeIgnored"] as? Bool) ?? false

        let path = (input["path"] as? String) ?? "."
        let rootURL: URL
        do {
            rootURL = try context.fileSystem.resolve(path)
        } catch {
            return .failure("Directory not found at path: \(path) (\(error.localizedDescription))", code: .notFound)
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDir) else {
            return .failure("Directory not found at path: \(path)", code: .notFound)
        }
        guard isDir.boolValue else {
            return .failure("Path '\(path)' is a file, not a directory. Use 'file_read' to view file contents.", code: .invalidInput)
        }

        var visited = Set<String>()
        var entryCount = 0
        var truncated = false
        let tree = generateTree(
            at: rootURL,
            depth: 0,
            maxDepth: maxDepth,
            showHidden: showHidden,
            includeIgnored: includeIgnored,
            visited: &visited,
            entryCount: &entryCount,
            truncated: &truncated
        )
        let suffix = truncated ? "\n… [truncated at 2000 entries]" : ""
        let output = """
        Project Tree for \(rootURL.lastPathComponent):
        \(tree)\(suffix)
        """
        return .success(output, data: [
            "tree": tree + suffix,
            "path": rootURL.path,
            "entries": "\(entryCount)",
            "truncated": truncated ? "true" : "false"
        ])
    }

    private func generateTree(
        at url: URL,
        depth: Int,
        maxDepth: Int,
        showHidden: Bool,
        includeIgnored: Bool,
        visited: inout Set<String>,
        entryCount: inout Int,
        truncated: inout Bool
    ) -> String {
        if depth > maxDepth { return "" }
        if truncated { return "" }

        var result = ""
        let indent = String(repeating: "  ", count: depth)
        result += "\(indent)📂 \(url.lastPathComponent)\n"

        // Cycle guard: never descend into a canonical directory twice.
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath().path
        if visited.contains(canonical) {
            return result + "\(indent)  ↩︎ [already visited: \(url.lastPathComponent)]\n"
        }
        visited.insert(canonical)

        do {
            let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
                options: options
            ).sorted(by: { $0.lastPathComponent < $1.lastPathComponent })

            for item in contents {
                if entryCount >= 2000 { truncated = true; break }
                let name = item.lastPathComponent
                if !showHidden && name.hasPrefix(".") { continue }
                if !includeIgnored && AssistWorkspaceScan.skippedDirs.contains(name) { continue }

                entryCount += 1
                let resourceValues = try? item.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                let isSymlink = resourceValues?.isSymbolicLink ?? false
                let isDir = resourceValues?.isDirectory ?? false

                if isSymlink {
                    result += "\(indent)  🔗 \(name)\n"
                } else if isDir {
                    result += generateTree(
                        at: item,
                        depth: depth + 1,
                        maxDepth: maxDepth,
                        showHidden: showHidden,
                        includeIgnored: includeIgnored,
                        visited: &visited,
                        entryCount: &entryCount,
                        truncated: &truncated
                    )
                } else {
                    result += "\(indent)  📄 \(name)\n"
                }
            }
        } catch {
            result += "\(indent)  ⚠️ Error reading directory: \(error.localizedDescription)\n"
        }
        return result
    }

    private static func parseDepth(_ value: Any) -> Int? {
        if let i = value as? Int, i >= 1 { return i }
        if let d = value as? Double, d >= 1, d == d.rounded() { return Int(d) }
        if let s = value as? String, let i = Int(s.trimmingCharacters(in: .whitespaces)), i >= 1 { return i }
        return nil
    }
}
