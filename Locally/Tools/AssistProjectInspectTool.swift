import Foundation

/// Inspects project structure, version control (git), Xcode targets, Swift Package Manager packages,
/// and finds symbol references across project source files.
public struct AssistProjectInspectTool: AssistTool {
    public let id = "project_inspect"
    public let name = "Project Inspection"
    public let description = "Inspects repository state (git status, diff, log), Xcode targets & configurations, SPM packages, or finds symbol references across the project."

    public init() {}

    public var capability: ToolCapability { .repositoryDiscovery }
    public var riskLevel: ToolRiskLevel { .safeRead }

    public var isReadOnly: Bool { true }
    public var isMutating: Bool { false }

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: "Inspects project structure, version control (git), Xcode targets, Swift Package Manager packages, or finds symbol references.",
            properties: [
                "operation": JSONSchema(
                    type: "string",
                    description: "The inspection operation to run: 'git_status', 'git_diff', 'git_log', 'xcode_targets', 'spm_packages', or 'find_symbol_references'.",
                    enumValues: ["git_status", "git_diff", "git_log", "xcode_targets", "spm_packages", "find_symbol_references"]
                ),
                "target": JSONSchema(
                    type: "string",
                    description: "Optional target parameter: specific Xcode target name for 'xcode_targets', commit count or file path for 'git_log' / 'git_diff', or symbol name for 'find_symbol_references'."
                ),
                "symbol": JSONSchema(
                    type: "string",
                    description: "Symbol name when operation is 'find_symbol_references' (can also be passed in 'target')."
                )
            ],
            required: ["operation"]
        )
    }

    public func execute(input: [String: Any], context: AssistContext) async throws -> AssistToolResult {
        guard let operation = input["operation"] as? String, !operation.isEmpty else {
            return .failure("Missing required parameter: operation", code: .missingArgument)
        }

        let target = (input["target"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let symbol = (input["symbol"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch operation.lowercased() {
        case "git_status":
            return await runGitStatus(context: context)
        case "git_diff":
            return await runGitDiff(target: target, context: context)
        case "git_log":
            return await runGitLog(target: target, context: context)
        case "xcode_targets":
            return await runXcodeTargets(target: target, context: context)
        case "spm_packages":
            return await runSPMPackages(context: context)
        case "find_symbol_references":
            let symbolName = (symbol?.isEmpty == false ? symbol : target) ?? ""
            return await runFindSymbolReferences(symbol: symbolName, context: context)
        default:
            return .failure(
                "Unknown operation '\(operation)'. Supported operations: git_status, git_diff, git_log, xcode_targets, spm_packages, find_symbol_references.",
                code: .unsupportedOperation
            )
        }
    }

    // MARK: - Git Operations

    private func runGitStatus(context: AssistContext) async -> AssistToolResult {
        let root = context.workspaceRoot
        let statusResult = await executeGit(["status", "--short", "--branch"], workingDirectory: root)
        if statusResult.exitCode != 0 {
            if statusResult.stderr.contains("not a git repository") || statusResult.stdout.contains("not a git repository") {
                return .success(
                    "Not a git repository: workspace at '\(root.path)' is not managed by Git.",
                    data: ["operation": "git_status", "isGit": "false"]
                )
            }
            return .failure("Git status failed: \(statusResult.stderr)", code: .executionFailed)
        }

        let rawShort = statusResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = rawShort.components(separatedBy: .newlines)
        let branchLine = lines.first ?? "## unknown"
        let fileLines = lines.dropFirst().filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        let isClean = fileLines.isEmpty
        var summaryLines: [String] = []
        summaryLines.append("Git Branch: \(branchLine.replacingOccurrences(of: "## ", with: ""))")
        if isClean {
            summaryLines.append("Working tree clean (no staged, unstaged, or untracked changes).")
        } else {
            summaryLines.append("Uncommitted changes (\(fileLines.count) items):")
            for line in fileLines {
                summaryLines.append("  \(line)")
            }
        }

        let output = summaryLines.joined(separator: "\n")
        return .success(
            output,
            data: [
                "operation": "git_status",
                "branch": branchLine,
                "isClean": "\(isClean)",
                "changesCount": "\(fileLines.count)"
            ]
        )
    }

    private func runGitDiff(target: String?, context: AssistContext) async -> AssistToolResult {
        let root = context.workspaceRoot
        var args = ["diff", "HEAD"]
        if let target = target, !target.isEmpty {
            args.append("--")
            args.append(target)
        }

        var diffResult = await executeGit(args, workingDirectory: root)
        // If HEAD is ambiguous (e.g. freshly initialized repo with no commits), fall back to git diff
        if diffResult.exitCode != 0 && diffResult.stderr.contains("ambiguous argument 'HEAD'") {
            diffResult = await executeGit(["diff"], workingDirectory: root)
        }

        if diffResult.exitCode != 0 {
            if diffResult.stderr.contains("not a git repository") {
                return .success(
                    "Not a git repository: workspace is not managed by Git.",
                    data: ["operation": "git_diff", "isGit": "false"]
                )
            }
            return .failure("Git diff failed: \(diffResult.stderr)", code: .executionFailed)
        }

        let diffOutput = diffResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if diffOutput.isEmpty {
            return .success(
                "Clean working tree: no uncommitted diff against HEAD.",
                data: ["operation": "git_diff", "hasDiff": "false"]
            )
        }

        // Also fetch stat summary for high-level context
        var statArgs = ["diff", "--stat", "HEAD"]
        if let target = target, !target.isEmpty {
            statArgs.append("--")
            statArgs.append(target)
        }
        let statResult = await executeGit(statArgs, workingDirectory: root)
        let statOutput = statResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        var combined = ""
        if !statOutput.isEmpty {
            combined = "Diff Summary:\n\(statOutput)\n\n"
        }
        combined += diffOutput

        let bounded = truncateIfNeeded(combined)
        return .success(
            bounded,
            data: [
                "operation": "git_diff",
                "hasDiff": "true",
                AssistToolDataKey.diff: bounded
            ]
        )
    }

    private func runGitLog(target: String?, context: AssistContext) async -> AssistToolResult {
        let root = context.workspaceRoot
        var count = 10
        var pathFilter: String? = nil

        if let target = target, !target.isEmpty {
            if let parsedInt = Int(target) {
                count = max(1, min(50, parsedInt))
            } else {
                pathFilter = target
            }
        }

        var args = [
            "log",
            "-n", "\(count)",
            "--pretty=format:%h | %ad | %s%d [%an]",
            "--date=short"
        ]
        if let pathFilter = pathFilter {
            args.append("--")
            args.append(pathFilter)
        }

        let result = await executeGit(args, workingDirectory: root)
        if result.exitCode != 0 {
            if result.stderr.contains("not a git repository") {
                return .success(
                    "Not a git repository: workspace is not managed by Git.",
                    data: ["operation": "git_log", "isGit": "false"]
                )
            }
            if result.stderr.contains("does not have any commits") {
                return .success(
                    "Git repository has no commits yet.",
                    data: ["operation": "git_log", "count": "0"]
                )
            }
            return .failure("Git log failed: \(result.stderr)", code: .executionFailed)
        }

        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.isEmpty {
            return .success("No commits found.", data: ["operation": "git_log", "count": "0"])
        }

        let lines = output.components(separatedBy: .newlines)
        var formatted = "Recent Git Commits (\(lines.count)):\n"
        formatted += output

        return .success(
            formatted,
            data: [
                "operation": "git_log",
                "count": "\(lines.count)"
            ]
        )
    }

    private func executeGit(_ arguments: [String], workingDirectory: URL) async -> (exitCode: Int32, stdout: String, stderr: String) {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            env["LANG"] = "en_US.UTF-8"
            process.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            do {
                try process.run()
            } catch {
                return (-1, "", "Failed to execute git: \(error.localizedDescription)")
            }

            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let stdout = String(data: outData, encoding: .utf8) ?? ""
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            return (process.terminationStatus, stdout, stderr)
        }.value
    }

    // MARK: - Xcode Targets Operation

    private func runXcodeTargets(target: String?, context: AssistContext) async -> AssistToolResult {
        let root = context.workspaceRoot
        let fm = FileManager.default

        // Find .xcodeproj bundles in workspace
        var xcodeProjURLs: [URL] = []
        if let contents = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            for url in contents where url.pathExtension == "xcodeproj" {
                xcodeProjURLs.append(url)
            }
        }

        if xcodeProjURLs.isEmpty {
            // Also search 1 level down
            if let contents = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
                for subDir in contents {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: subDir.path, isDirectory: &isDir), isDir.boolValue {
                        if let subContents = try? fm.contentsOfDirectory(at: subDir, includingPropertiesForKeys: [.isDirectoryKey]) {
                            for url in subContents where url.pathExtension == "xcodeproj" {
                                xcodeProjURLs.append(url)
                            }
                        }
                    }
                }
            }
        }

        guard !xcodeProjURLs.isEmpty else {
            return .success(
                "No .xcodeproj found in workspace '\(root.path)'.",
                data: ["operation": "xcode_targets", "projectCount": "0"]
            )
        }

        var report = "Xcode Projects & Targets:\n"

        for projURL in xcodeProjURLs {
            let projName = projURL.deletingPathExtension().lastPathComponent
            let pbxprojURL = projURL.appendingPathComponent("project.pbxproj")
            guard let pbxContent = try? String(contentsOf: pbxprojURL, encoding: .utf8) else {
                report += "\n- Project: \(projName) (could not read project.pbxproj)\n"
                continue
            }

            report += "\n=== Project: \(projName) (\(projURL.lastPathComponent)) ===\n"

            // Extract PBXNativeTarget blocks
            let targetMatches = extractTargets(from: pbxContent)
            report += "Targets (\(targetMatches.count)):\n"

            for t in targetMatches {
                report += "  • \(t.name) [Type: \(t.productType)]\n"
                if !t.configurations.isEmpty {
                    report += "    Build Configurations: \(t.configurations.joined(separator: ", "))\n"
                }

                // If specific target was requested, list its source files
                if let requested = target, requested.lowercased() == t.name.lowercased() {
                    let files = listFilesForTarget(name: t.name, pbxContent: pbxContent, root: root)
                    report += "    Source Files (\(files.count)):\n"
                    for f in files.prefix(40) {
                        report += "      - \(f)\n"
                    }
                    if files.count > 40 {
                        report += "      ... and \(files.count - 40) more source files\n"
                    }
                }
            }

            // Extract Schemes if present in xcshareddata
            let schemesURL = projURL.appendingPathComponent("xcshareddata/xcschemes")
            if let schemeFiles = try? fm.contentsOfDirectory(at: schemesURL, includingPropertiesForKeys: nil) {
                let schemes = schemeFiles.filter { $0.pathExtension == "xcscheme" }.map { $0.deletingPathExtension().lastPathComponent }
                if !schemes.isEmpty {
                    report += "\nShared Schemes: \(schemes.joined(separator: ", "))\n"
                }
            }
        }

        let bounded = truncateIfNeeded(report)
        return .success(bounded, data: ["operation": "xcode_targets"])
    }

    private struct ParsedTarget {
        let name: String
        let productType: String
        let configurations: [String]
    }

    private func extractTargets(from pbxContent: String) -> [ParsedTarget] {
        var targets: [ParsedTarget] = []

        // Extract native target sections
        let targetRegex = try? NSRegularExpression(
            pattern: "isa = PBXNativeTarget;[\\s\\S]*?name = \"?([^;\"]+)\"?;[\\s\\S]*?productType = \"?([^;\"]+)\"?;",
            options: []
        )

        let range = NSRange(location: 0, length: pbxContent.utf16.count)
        targetRegex?.enumerateMatches(in: pbxContent, options: [], range: range) { match, _, _ in
            guard let match = match,
                  let nameRange = Range(match.range(at: 1), in: pbxContent),
                  let typeRange = Range(match.range(at: 2), in: pbxContent) else { return }

            let name = String(pbxContent[nameRange])
            let productType = String(pbxContent[typeRange])
                .replacingOccurrences(of: "com.apple.product-type.", with: "")

            // Extract configurations (Debug, Release)
            var configs: [String] = []
            if pbxContent.contains("/* Debug */") || pbxContent.contains("name = Debug;") {
                configs.append("Debug")
            }
            if pbxContent.contains("/* Release */") || pbxContent.contains("name = Release;") {
                configs.append("Release")
            }

            targets.append(ParsedTarget(name: name, productType: productType, configurations: configs))
        }

        return targets
    }

    private func listFilesForTarget(name: String, pbxContent: String, root: URL) -> [String] {
        let fm = FileManager.default
        var files: [String] = []

        // 1. Check for directory with target name (Xcode 16 synchronized groups)
        let targetDir = root.appendingPathComponent(name)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: targetDir.path, isDirectory: &isDir), isDir.boolValue {
            if let enumerator = fm.enumerator(at: targetDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                while let fileURL = enumerator.nextObject() as? URL {
                    if let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true {
                        let rel = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
                        files.append(rel)
                    }
                }
            }
        }

        // 2. Also check PBXBuildFile references in Sources phase
        if files.isEmpty {
            let sourceFileRegex = try? NSRegularExpression(
                pattern: "/\\*\\s*([^/\\*]+\\.(?:swift|m|mm|c|cpp|h)) in Sources \\*/",
                options: []
            )
            let range = NSRange(location: 0, length: pbxContent.utf16.count)
            sourceFileRegex?.enumerateMatches(in: pbxContent, options: [], range: range) { match, _, _ in
                guard let match = match, let fileRange = Range(match.range(at: 1), in: pbxContent) else { return }
                files.append(String(pbxContent[fileRange]))
            }
        }

        return files.sorted()
    }

    // MARK: - SPM Packages Operation

    private func runSPMPackages(context: AssistContext) async -> AssistToolResult {
        let root = context.workspaceRoot
        let fm = FileManager.default

        var report = "Swift Package Manager Dependencies:\n"
        var foundAny = false

        // 1. Inspect Package.swift if present at root
        let packageSwiftURL = root.appendingPathComponent("Package.swift")
        if let packageContent = try? String(contentsOf: packageSwiftURL, encoding: .utf8) {
            foundAny = true
            report += "\n=== Root Package.swift ===\n"

            // Package name
            if let nameMatch = packageContent.range(of: #"name:\s*"([^"]+)""#, options: .regularExpression) {
                let nameSub = packageContent[nameMatch]
                report += "\(nameSub)\n"
            }

            // Dependencies
            let depRegex = try? NSRegularExpression(pattern: #"\.package\s*\([^)]+\)"#, options: [])
            let range = NSRange(location: 0, length: packageContent.utf16.count)
            var deps: [String] = []
            depRegex?.enumerateMatches(in: packageContent, options: [], range: range) { match, _, _ in
                if let match = match, let matchRange = Range(match.range, in: packageContent) {
                    let cleaned = String(packageContent[matchRange])
                        .replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "  ", with: " ")
                    deps.append(cleaned)
                }
            }

            if !deps.isEmpty {
                report += "Declared Dependencies (\(deps.count)):\n"
                for d in deps {
                    report += "  • \(d)\n"
                }
            }
        }

        // 2. Inspect Package.resolved files
        var resolvedURLs: [URL] = []
        let rootResolved = root.appendingPathComponent("Package.resolved")
        if fm.fileExists(atPath: rootResolved.path) {
            resolvedURLs.append(rootResolved)
        }

        // Check Xcode shared Package.resolved locations
        if let contents = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for url in contents where url.pathExtension == "xcodeproj" || url.pathExtension == "xcworkspace" {
                let xcodeResolved = url.appendingPathComponent("project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
                if fm.fileExists(atPath: xcodeResolved.path) {
                    resolvedURLs.append(xcodeResolved)
                }
                let altResolved = url.appendingPathComponent("xcshareddata/swiftpm/Package.resolved")
                if fm.fileExists(atPath: altResolved.path) {
                    resolvedURLs.append(altResolved)
                }
            }
        }

        for resURL in resolvedURLs {
            foundAny = true
            let rel = resURL.path.replacingOccurrences(of: root.path + "/", with: "")
            report += "\n=== Resolved Pins (\(rel)) ===\n"

            if let data = try? Data(contentsOf: resURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let pins = json["pins"] as? [[String: Any]] {
                report += "Total Packages: \(pins.count)\n"
                for pin in pins {
                    let identity = pin["identity"] as? String ?? pin["package"] as? String ?? "unknown"
                    let location = pin["location"] as? String ?? pin["repositoryURL"] as? String ?? ""
                    let state = pin["state"] as? [String: Any] ?? [:]
                    let version = state["version"] as? String ?? state["branch"] as? String ?? "unknown"
                    let revision = state["revision"] as? String ?? ""
                    let revShort = revision.count > 8 ? String(revision.prefix(8)) : revision

                    report += "  • \(identity) (\(version))\n"
                    if !location.isEmpty {
                        report += "    Location: \(location)\n"
                    }
                    if !revShort.isEmpty {
                        report += "    Revision: \(revShort)\n"
                    }
                }
            }
        }

        guard foundAny else {
            return .success(
                "No Swift Package Manager packages or Package.swift found in workspace.",
                data: ["operation": "spm_packages", "count": "0"]
            )
        }

        let bounded = truncateIfNeeded(report)
        return .success(bounded, data: ["operation": "spm_packages"])
    }

    // MARK: - Symbol References Operation

    private func runFindSymbolReferences(symbol: String, context: AssistContext) async -> AssistToolResult {
        guard !symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("Missing required parameter: 'symbol' (or 'target') for find_symbol_references", code: .missingArgument)
        }

        let root = context.workspaceRoot

        // Fast grep execution with folder exclusions
        let grepArgs = [
            "-rn",
            "--exclude-dir=build",
            "--exclude-dir=DerivedData",
            "--exclude-dir=.build",
            "--exclude-dir=.git",
            "--exclude-dir=.xcodeproj",
            "--exclude-dir=.xcworkspace",
            "--exclude-dir=Pods",
            "--exclude-dir=node_modules",
            "-E",
            "\\b\(NSRegularExpression.escapedPattern(for: symbol))\\b",
            "."
        ]

        let grepResult = await Task.detached { () -> (exitCode: Int32, stdout: String) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
            process.arguments = grepArgs
            process.currentDirectoryURL = root

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            process.environment = env

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            do {
                try process.run()
            } catch {
                return (-1, "")
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let stdout = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus, stdout)
        }.value

        var matches: [String] = []

        if grepResult.exitCode == 0 && !grepResult.stdout.isEmpty {
            for line in grepResult.stdout.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    // Normalize leading ./
                    let clean = trimmed.hasPrefix("./") ? String(trimmed.dropFirst(2)) : trimmed
                    matches.append(clean)
                }
            }
        } else {
            // Swift fallback scan if grep returns no results or fails
            let codeExtensions: Set<String> = ["swift", "h", "m", "c", "cpp"]
            let skipped: Set<String> = ["build", "DerivedData", ".build", ".git", ".xcodeproj", ".xcworkspace", "Pods"]

            let fm = FileManager.default
            if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], options: [.skipsHiddenFiles]) {
                let escaped = NSRegularExpression.escapedPattern(for: symbol)
                let regex = try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: [])

                while let fileURL = enumerator.nextObject() as? URL {
                    let name = fileURL.lastPathComponent
                    if skipped.contains(name) {
                        enumerator.skipDescendants()
                        continue
                    }
                    guard codeExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
                    guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

                    let rel = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
                    let lines = content.components(separatedBy: .newlines)
                    for (i, line) in lines.enumerated() {
                        let range = NSRange(location: 0, length: line.utf16.count)
                        if regex?.firstMatch(in: line, options: [], range: range) != nil {
                            matches.append("\(rel):\(i + 1): \(line.trimmingCharacters(in: .whitespaces))")
                            if matches.count >= 150 { break }
                        }
                    }
                    if matches.count >= 150 { break }
                }
            }
        }

        if matches.isEmpty {
            return .success(
                "No references to '\(symbol)' found in project code files.",
                data: [
                    "operation": "find_symbol_references",
                    "symbol": symbol,
                    "count": "0"
                ]
            )
        }

        var report = "Symbol references for '\(symbol)' (\(matches.count) found):\n"
        for m in matches.prefix(100) {
            report += "  \(m)\n"
        }
        if matches.count > 100 {
            report += "  ... and \(matches.count - 100) more matches truncated.\n"
        }

        let bounded = truncateIfNeeded(report)
        return .success(
            bounded,
            data: [
                "operation": "find_symbol_references",
                "symbol": symbol,
                "count": "\(matches.count)"
            ]
        )
    }

    // MARK: - Truncation Helper

    private func truncateIfNeeded(_ text: String, limit: Int = 40_000) -> String {
        if text.count <= limit {
            return text
        }
        let prefix = text.prefix(limit)
        return "\(prefix)\n... [Output truncated: showing first \(limit.formatted(.number)) characters. Use line ranges or grep to inspect specific sections.]"
    }
}
