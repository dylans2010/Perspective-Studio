import Foundation

public struct AssistReadFileTool: AssistTool {
    public let id = "file_read"
    public let name = "Read File"
    public let description = "Reads the content of a file at the specified path. Pass lines {start,end} for a 1-based inclusive line range; omit lines to read the whole file."

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: "Reads the content of a file at the specified path. Pass lines {start,end} for a 1-based inclusive line range; omit lines to read the whole file.",
            properties: [
                "path": JSONSchema(type: "string", description: "The relative path to the file from the workspace root."),
                "lines": JSONSchema(
                    type: "object",
                    description: "Optional 1-based inclusive line range. start defaults to 1, end defaults to the last line. Both must be integers >= 1; start must be <= end. Out-of-range end is clamped to the last line; out-of-range start (start > totalLines) is an error, never invented content.",
                    properties: [
                        "start": JSONSchema(type: "integer", description: "1-based first line to return. Default: 1."),
                        "end": JSONSchema(type: "integer", description: "1-based last line to return, inclusive. Default: last line.")
                    ]
                ),
                "maxBytes": JSONSchema(type: "integer", description: "Optional maximum number of bytes to read.")
            ],
            required: ["path"]
        )
    }

    public init() {}

    public var capability: ToolCapability { .fileReading }
    public var riskLevel: ToolRiskLevel { .safeRead }

    public func execute(input: [String: Any], context: AssistContext) async throws -> AssistToolResult {
        guard let rawPath = (input["path"] ?? input["filePath"] ?? input["file_path"] ?? input["targetFile"] ?? input["file"]) as? String,
              !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("Missing required parameter: path", code: .missingArgument)
        }

        let resolvedURL: URL
        do {
            resolvedURL = try context.fileSystem.resolve(rawPath)
        } catch {
            return .failure("File does not exist at path: '\(rawPath)'. Use 'file_search' or 'dir_read' to discover available files.", code: .notFound)
        }
        let resolvedPath = resolvedURL.path

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: resolvedPath, isDirectory: &isDir) else {
            return .failure("File does not exist at path: '\(rawPath)' (resolved: '\(resolvedPath)'). Use 'file_search' or 'dir_read' to discover available files.", code: .notFound)
        }
        if isDir.boolValue {
            return .failure("Path '\(rawPath)' is a directory, not a file. Use 'dir_read' to list directory contents or 'tree_view' for a project tree.", code: .invalidInput)
        }

        let attrs = (try? fm.attributesOfItem(atPath: resolvedPath)) ?? [:]
        let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0

        if fileSize == 0 {
            return .success("File is empty: \(rawPath)", data: [
                "content": "",
                "path": resolvedPath,
                "start": "1",
                "end": "0",
                "totalLines": "0",
                "fullyAvailable": "true"
            ])
        }

        let ext = resolvedURL.pathExtension.lowercased()
        let binaryExtensions: Set<String> = [
            "png", "jpg", "jpeg", "gif", "ico", "pdf", "zip", "tar", "gz",
            "dylib", "a", "o", "so", "bin", "exe", "dmg", "pkg", "car", "nib",
            "storyboardc", "ds_store", "mp3", "mp4", "mov", "wav", "m4a", "flac"
        ]
        let formattedSize = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
        if binaryExtensions.contains(ext) {
            return .failure("File '\(rawPath)' is a binary or unsupported file (\(formattedSize), extension: .\(ext)). Text content cannot be read.", code: .invalidInput)
        }

        var maxBytesToRead = 10_000_000
        if let userMaxBytes = input["maxBytes"] as? Int, userMaxBytes > 0 {
            maxBytesToRead = min(userMaxBytes, maxBytesToRead)
        } else if let userMaxBytesD = input["maxBytes"] as? Double, userMaxBytesD > 0 {
            maxBytesToRead = min(Int(userMaxBytesD), maxBytesToRead)
        }

        guard let handle = try? FileHandle(forReadingFrom: resolvedURL) else {
            return .failure("Failed to open file at '\(rawPath)' for reading.", code: .executionFailed)
        }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: maxBytesToRead) else {
            return .failure("Failed to read file data at '\(rawPath)'.", code: .executionFailed)
        }

        let sampleCheckCount = min(data.count, 8192)
        if sampleCheckCount > 0 {
            let sample = data.prefix(sampleCheckCount)
            if sample.contains(0) {
                return .failure("File '\(rawPath)' appears to be a binary file (\(formattedSize), contains null bytes). Text content cannot be read.", code: .invalidInput)
            }
        }

        guard let content = String(data: data, encoding: .utf8) else {
            return .failure("File '\(rawPath)' cannot be decoded as UTF-8 text (\(formattedSize)). It may be a binary or non-UTF8 encoded file.", code: .invalidInput)
        }

        var lines = content.components(separatedBy: .newlines)
        if lines.last == "" { lines.removeLast() }
        let totalLines = lines.count

        if totalLines == 0 {
            return .success("File is empty: \(rawPath)", data: [
                "content": "",
                "path": resolvedPath,
                "start": "1",
                "end": "0",
                "totalLines": "0",
                "fullyAvailable": "true"
            ])
        }

        var start = 1
        var end = totalLines
        var linesArg = input["lines"] as? [String: Any]
        if linesArg == nil, let linesString = input["lines"] as? String,
           let linesData = linesString.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: linesData) as? [String: Any] {
            linesArg = parsed
        }
        if let range = linesArg {
            if let rawStart = range["start"] {
                guard let parsed = Self.parseLineNumber(rawStart) else {
                    return .failure("Invalid lines.start: must be an integer >= 1 (got '\(rawStart)').", code: .invalidInput)
                }
                start = parsed
            }
            if let rawEnd = range["end"] {
                guard let parsed = Self.parseLineNumber(rawEnd) else {
                    return .failure("Invalid lines.end: must be an integer >= 1 (got '\(rawEnd)').", code: .invalidInput)
                }
                end = parsed
            }
        }
        if start > end {
            return .failure("Invalid line range: start (\(start)) > end (\(end)). Lines are 1-based inclusive.", code: .invalidInput)
        }
        if start > totalLines {
            return .failure("Line range start (\(start)) exceeds total lines (\(totalLines)) in \(rawPath). No content invented.", code: .invalidInput)
        }

        let clampedEnd = min(end, totalLines)
        let slice = lines[(start - 1)...(clampedEnd - 1)]
        let numbered = slice.enumerated()
            .map { "\(start + $0.offset): \($0.element)" }
            .joined(separator: "\n")
        let fullyAvailable = (start == 1 && clampedEnd == totalLines && Int64(data.count) >= fileSize)

        var truncationNote = ""
        if !fullyAvailable {
            if Int64(data.count) < fileSize {
                truncationNote = "\n[File truncated at \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)) of \(formattedSize). Pass lines or increase maxBytes to read more.]"
            } else {
                truncationNote = "\n[Showing lines \(start)-\(clampedEnd) of \(totalLines). More lines available.]"
            }
        }

        let output = """
        Successfully read file: \(rawPath) (lines \(start)-\(clampedEnd) of \(totalLines)):
        \(numbered)\(truncationNote)
        """
        return .success(output, data: [
            "content": numbered,
            "path": resolvedPath,
            "start": "\(start)",
            "end": "\(clampedEnd)",
            "totalLines": "\(totalLines)",
            "fullyAvailable": fullyAvailable ? "true" : "false"
        ])
    }

    private static func parseLineNumber(_ value: Any) -> Int? {
        if let i = value as? Int, i >= 1 { return i }
        if let d = value as? Double, d >= 1, d == d.rounded(), d <= Double(Int.max) { return Int(d) }
        if let s = value as? String, let i = Int(s.trimmingCharacters(in: .whitespaces)), i >= 1 { return i }
        return nil
    }
}
