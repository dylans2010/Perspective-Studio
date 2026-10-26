import Foundation
import os

/// Executes shell commands via `/bin/zsh` within the project workspace.
/// Captures stdout, stderr, exit code, and execution duration.
/// Defaults to the active session working directory if `workingDirectory` is omitted.
public struct AssistTerminalTool: AssistTool {
    public let id: String
    public let name = "Terminal Shell Execution"
    public let description = "Executes a shell command via /bin/zsh in the workspace directory. Captures stdout, stderr, exit code, and execution time. Defaults to session working directory when workingDirectory is omitted."

    public init(id: String = "use_terminal") {
        self.id = id
    }

    public var capability: ToolCapability { .systemExecution }
    public var riskLevel: ToolRiskLevel { .execution }

    public var isReadOnly: Bool { false }
    public var isMutating: Bool { true }

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: "Executes a shell command via /bin/zsh in the workspace directory. Captures stdout, stderr, exit code, and execution time.",
            properties: [
                "command": JSONSchema(
                    type: "string",
                    description: "The shell command to execute."
                ),
                "workingDirectory": JSONSchema(
                    type: "string",
                    description: "Directory relative to workspace root (or session working directory). Defaults to context.fileSystem.currentDirectory."
                ),
                "timeout": JSONSchema(
                    type: "number",
                    description: "Timeout in seconds (default: 30s, max: 120s)."
                )
            ],
            required: ["command"]
        )
    }

    public func execute(input: [String: Any], context: AssistContext) async throws -> AssistToolResult {
        guard let command = input["command"] as? String, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("Missing required parameter: command", code: .missingArgument)
        }

        // 1. Security Check: Block forbidden dangerous commands
        if let securityReason = TerminalSecurityGuard.validate(command: command) {
            return .failure(
                "Security Error: Forbidden command pattern: \(securityReason)",
                code: .permissionDenied,
                diagnostics: ["Security violation blocked for command: \(command)"]
            )
        }

        // 2. Resolve & Validate Working Directory
        let resolvedDir: URL
        if let requestedDir = input["workingDirectory"] as? String, !requestedDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmed = requestedDir.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("/") {
                let candidate = URL(fileURLWithPath: trimmed).standardized
                let rootPath = context.workspaceRoot.standardizedFileURL.resolvingSymlinksInPath().path
                let targetPath = candidate.resolvingSymlinksInPath().path
                let isWithinWorkspace = (targetPath == rootPath || targetPath.hasPrefix(rootPath + "/"))
                let isAllowedTemp = (targetPath == "/tmp/swiftcode/scripts" || targetPath.hasPrefix("/tmp/swiftcode/scripts/"))
                guard isWithinWorkspace || isAllowedTemp else {
                    return .failure(
                        "Security Error: Working directory '\(targetPath)' is outside workspace bounds.",
                        code: .permissionDenied
                    )
                }
                resolvedDir = candidate
            } else {
                do {
                    resolvedDir = try context.fileSystem.resolve(trimmed)
                } catch {
                    return .failure("Invalid workingDirectory '\(trimmed)': \(error.localizedDescription)", code: .invalidInput)
                }
            }
        } else {
            resolvedDir = context.fileSystem.currentDirectory
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedDir.path, isDirectory: &isDir), isDir.boolValue else {
            return .failure("Working directory does not exist or is not a directory: \(resolvedDir.path)", code: .notFound)
        }

        // Security boundary validation
        let rootPath = context.workspaceRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let targetPath = resolvedDir.standardizedFileURL.resolvingSymlinksInPath().path
        let isWithinWorkspace = (targetPath == rootPath || targetPath.hasPrefix(rootPath + "/"))
        let isAllowedTemp = (targetPath == "/tmp/swiftcode/scripts" || targetPath.hasPrefix("/tmp/swiftcode/scripts/"))
        guard isWithinWorkspace || isAllowedTemp else {
            return .failure(
                "Security Error: Working directory '\(targetPath)' is outside workspace bounds.",
                code: .permissionDenied
            )
        }

        // 3. Timeout Configuration
        let rawTimeout = (input["timeout"] as? NSNumber)?.doubleValue ?? 30.0
        let timeout = max(1.0, min(120.0, rawTimeout))

        // 4. Run Process
        let result = await Self.runProcess(
            command: command,
            workingDirectory: resolvedDir,
            timeout: timeout
        )

        // 5. Bounded Output Truncation (40,000 character limit)
        let cleanStdout = Self.truncateIfNeeded(result.stdout)
        let cleanStderr = Self.truncateIfNeeded(result.stderr)
        let durationMs = Int((result.duration * 1000).rounded())

        let data: [String: String] = [
            AssistToolDataKey.exitCode: "\(result.exitCode)",
            AssistToolDataKey.stdout: cleanStdout,
            AssistToolDataKey.stderr: cleanStderr,
            AssistToolDataKey.durationMs: "\(durationMs)",
            AssistToolDataKey.path: resolvedDir.path
        ]

        if result.timedOut {
            var output = "Command timed out after \(Int(timeout))s."
            if !cleanStdout.isEmpty {
                output += "\n\(cleanStdout)"
            }
            if !cleanStderr.isEmpty {
                output += "\n[stderr]\n\(cleanStderr)"
            }
            return AssistToolResult(
                success: false,
                output: output,
                data: data,
                error: "Command timed out after \(Int(timeout))s",
                duration: result.duration,
                exitCode: -1,
                toolErrorCode: .timeout
            )
        }

        if result.exitCode == 0 {
            let output: String
            if cleanStdout.isEmpty && cleanStderr.isEmpty {
                output = "Command succeeded with no output (exit code 0)"
            } else if !cleanStdout.isEmpty && cleanStderr.isEmpty {
                output = cleanStdout
            } else if cleanStdout.isEmpty && !cleanStderr.isEmpty {
                output = "[stderr]\n\(cleanStderr)"
            } else {
                output = "\(cleanStdout)\n\n[stderr]\n\(cleanStderr)"
            }

            return AssistToolResult(
                success: true,
                output: output,
                data: data,
                duration: result.duration,
                exitCode: 0
            )
        } else {
            let combined = "\(cleanStdout)\n\(cleanStderr)".trimmingCharacters(in: .whitespacesAndNewlines)
            let output: String
            if combined.isEmpty {
                output = "Command failed with exit code \(result.exitCode) (no output produced)."
            } else {
                output = "Command failed with exit code \(result.exitCode):\n\(combined)"
            }

            return AssistToolResult(
                success: false,
                output: output,
                data: data,
                error: "Command failed with exit code \(result.exitCode)",
                duration: result.duration,
                exitCode: result.exitCode,
                toolErrorCode: .executionFailed
            )
        }
    }

    // MARK: - Process Execution

    private struct ExecutionResult: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        let duration: TimeInterval
        let timedOut: Bool
    }

    private static func runProcess(
        command: String,
        workingDirectory: URL,
        timeout: TimeInterval
    ) async -> ExecutionResult {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]
            process.currentDirectoryURL = workingDirectory

            var env = ProcessInfo.processInfo.environment
            let safePath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            if let existingPath = env["PATH"], !existingPath.isEmpty {
                env["PATH"] = "\(safePath):\(existingPath)"
            } else {
                env["PATH"] = safePath
            }
            env["LANG"] = "en_US.UTF-8"
            env["LC_ALL"] = "en_US.UTF-8"
            env["TERM"] = "dumb"
            process.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            final class StreamAccumulator: @unchecked Sendable {
                private let lock = NSLock()
                private var data = Data()

                func append(_ chunk: Data) {
                    lock.withLock {
                        data.append(chunk)
                    }
                }

                func finish() -> Data {
                    lock.withLock { data }
                }
            }

            let outAccumulator = StreamAccumulator()
            let errAccumulator = StreamAccumulator()

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty {
                    outAccumulator.append(chunk)
                }
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty {
                    errAccumulator.append(chunk)
                }
            }

            let start = Date()

            do {
                try process.run()
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                return ExecutionResult(
                    exitCode: -1,
                    stdout: "",
                    stderr: "Failed to launch /bin/zsh: \(error.localizedDescription)",
                    duration: Date().timeIntervalSince(start),
                    timedOut: false
                )
            }

            actor ProcessTimeoutGate {
                private var finished = false
                func claim() -> Bool {
                    if finished { return false }
                    finished = true
                    return true
                }
            }

            let gate = ProcessTimeoutGate()
            let timedOut = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                process.terminationHandler = { _ in
                    Task {
                        if await gate.claim() {
                            continuation.resume(returning: false)
                        }
                    }
                }
                Task {
                    try? await Task.sleep(for: .seconds(timeout))
                    if await gate.claim() {
                        process.terminate()
                        continuation.resume(returning: true)
                    }
                }
            }

            if timedOut {
                try? await Task.sleep(for: .seconds(1))
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }

            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil

            let outRemainder = outPipe.fileHandleForReading.readDataToEndOfFile()
            if !outRemainder.isEmpty {
                outAccumulator.append(outRemainder)
            }
            let errRemainder = errPipe.fileHandleForReading.readDataToEndOfFile()
            if !errRemainder.isEmpty {
                errAccumulator.append(errRemainder)
            }

            let duration = Date().timeIntervalSince(start)
            let outText = String(data: outAccumulator.finish(), encoding: .utf8) ?? ""
            let errText = String(data: errAccumulator.finish(), encoding: .utf8) ?? ""

            return ExecutionResult(
                exitCode: timedOut ? -1 : process.terminationStatus,
                stdout: outText,
                stderr: errText,
                duration: duration,
                timedOut: timedOut
            )
        }.value
    }

    // MARK: - Truncation

    private static func truncateIfNeeded(_ text: String, limit: Int = 40_000) -> String {
        if text.count <= limit {
            return text
        }
        let prefix = text.prefix(limit)
        return "\(prefix)\n... [Output truncated: showing first \(limit.formatted(.number)) characters. Use line ranges or grep to inspect specific sections.]"
    }
}

// MARK: - Terminal Security Guard

private enum TerminalSecurityGuard {
    private static let forbiddenRules: [(pattern: String, reason: String)] = [
        ("\\bsudo\\b", "Privilege escalation with 'sudo' is forbidden."),
        ("\\brm\\s+-[a-zA-Z]*r[a-zA-Z]*f[a-zA-Z]*\\s+/(?:\\s*|\\*)", "Destructive recursive deletion of system root ('rm -rf /') is forbidden."),
        ("\\brm\\s+-[a-zA-Z]*f[a-zA-Z]*r[a-zA-Z]*\\s+/(?:\\s*|\\*)", "Destructive recursive deletion of system root ('rm -rf /') is forbidden."),
        ("\\brm\\s+-[a-zA-Z]*r[a-zA-Z]*f[a-zA-Z]*\\s+~", "Destructive deletion of user home directory is forbidden."),
        ("\\bdiskutil\\s+(eraseDisk|partitionDisk|zeroDisk|randomDisk|secureErase|apfs\\s+deleteVolume)", "Disk modification and formatting via diskutil is forbidden."),
        ("\\b(mkfs|newfs)\\b", "Filesystem creation/formatting commands are forbidden."),
        ("\\bdd\\s+if=", "Low-level block device manipulation with 'dd' is forbidden."),
        ("\\b(shutdown|reboot|halt|poweroff|init\\s+[06])\\b", "System shutdown and reboot commands are forbidden."),
        (":\\(\\)\\s*\\{\\s*:\\|:&\\s*\\};:", "Fork bomb pattern is forbidden."),
        ("\\b(chown|chmod)\\s+-[a-zA-Z]*R[a-zA-Z]*\\s+/(?:\\s|$)", "Recursive ownership/permission modification at filesystem root is forbidden."),
        ("(?:>|>>)\\s*/(?:System|Library|etc|bin|sbin|usr)(?:/|\\s|$)", "Direct redirection or writes to system directories is forbidden.")
    ]

    static func validate(command: String) -> String? {
        for (pattern, reason) in forbiddenRules {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(location: 0, length: command.utf16.count)
                if regex.firstMatch(in: command, options: [], range: range) != nil {
                    return reason
                }
            }
        }
        return nil
    }
}
