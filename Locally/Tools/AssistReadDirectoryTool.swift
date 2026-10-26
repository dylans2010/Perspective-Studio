import Foundation

public struct AssistReadDirectoryTool: AssistTool {
    public let id = "dir_read"
    public let name = "Read Directory"
    public let description = "Lists the contents of a directory (native ls equivalent). Returns sorted entries with directory markers, file/directory counts, and total size. Non-recursive — use tree_view for a recursive listing."

    public init() {}

    public var capability: ToolCapability { .fileReading }
    public var riskLevel: ToolRiskLevel { .safeRead }

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: "Lists the contents of a directory. Returns sorted entries; directory entries are suffixed with '/', symlinks with '@'.",
            properties: [
                "path": JSONSchema(type: "string", description: "Workspace-relative path of the directory to list. Use \".\" for the session working directory."),
                "showHidden": JSONSchema(type: "boolean", description: "Whether to include hidden files and directories (default: false).")
            ],
            required: ["path"]
        )
    }

    public func execute(input: [String: Any], context: AssistContext) async throws -> AssistToolResult {
        guard let path = (input["path"] ?? input["directory"] ?? input["dir"]) as? String else {
            return .failure("Missing required parameter: path", code: .missingArgument)
        }

        let showHidden = (input["showHidden"] as? Bool) ?? false

        let resolvedURL: URL
        do {
            resolvedURL = try context.fileSystem.resolve(path)
        } catch {
            return .failure("Directory not found at path: '\(path)' (\(error.localizedDescription))", code: .notFound)
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: resolvedURL.path, isDirectory: &isDir) else {
            return .failure("Directory not found at path: '\(path)'", code: .notFound)
        }
        guard isDir.boolValue else {
            return .failure("Path '\(path)' is a file, not a directory. Use 'file_read' to view file contents.", code: .invalidInput)
        }

        do {
            let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
            let contents = try fm.contentsOfDirectory(
                at: resolvedURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
                options: options
            ).sorted(by: { $0.lastPathComponent < $1.lastPathComponent })

            var annotated: [String] = []
            var fileCount = 0
            var dirCount = 0
            var symlinkCount = 0
            var totalBytes: Int64 = 0

            for item in contents {
                let name = item.lastPathComponent
                if !showHidden && name.hasPrefix(".") { continue }

                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
                let isSymlink = values?.isSymbolicLink ?? false
                let isItemDir = values?.isDirectory ?? false
                let size = Int64(values?.fileSize ?? 0)

                if isSymlink {
                    symlinkCount += 1
                    let dest = (try? fm.destinationOfSymbolicLink(atPath: item.path)) ?? "unknown"
                    annotated.append("\(name)@ -> \(dest)")
                } else if isItemDir {
                    dirCount += 1
                    annotated.append("\(name)/")
                } else {
                    fileCount += 1
                    totalBytes += size
                    annotated.append(name)
                }
            }

            let listing = annotated.isEmpty ? "(directory is empty)" : annotated.joined(separator: "\n")
            let formattedSize = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            let summary = "Summary: \(fileCount) files, \(dirCount) directories, \(symlinkCount) symlinks (\(formattedSize))"
            let output = """
            Directory \(path) (\(annotated.count) entries):
            \(listing)

            \(summary)
            """

            return .success(
                output,
                data: [
                    "contents": annotated.joined(separator: "\n"),
                    "count": "\(annotated.count)",
                    "fileCount": "\(fileCount)",
                    "dirCount": "\(dirCount)",
                    "symlinkCount": "\(symlinkCount)",
                    "totalBytes": "\(totalBytes)",
                    "formattedTotalSize": formattedSize,
                    "path": resolvedURL.path
                ]
            )
        } catch {
            return .failure("Failed to read directory at \(path): \(error.localizedDescription)", code: .executionFailed)
        }
    }
}
