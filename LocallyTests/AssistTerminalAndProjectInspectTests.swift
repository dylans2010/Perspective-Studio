import XCTest
@testable import Locally

@MainActor
final class AssistTerminalAndProjectInspectTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("assist-terminal-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - AssistTerminalTool Tests

    func testTerminalToolExecutionSuccess() async throws {
        let tool = AssistTerminalTool()
        let context = AssistContext(workspaceRoot: tempDir)

        let result = try await tool.execute(
            input: ["command": "echo 'Hello from Terminal'"],
            context: context
        )

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("Hello from Terminal"))
        XCTAssertEqual(result.data?[AssistToolDataKey.exitCode], "0")
        XCTAssertNotNil(result.data?[AssistToolDataKey.durationMs])
        XCTAssertEqual(result.data?[AssistToolDataKey.path], tempDir.path)
    }

    func testTerminalToolWorkingDirectoryInheritanceAndResolution() async throws {
        let subDir = tempDir.appendingPathComponent("sub_folder")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let context = AssistContext(workspaceRoot: tempDir)
        _ = try context.fileSystem.setCurrentDirectory("sub_folder")

        let tool = AssistTerminalTool()
        let result = try await tool.execute(
            input: ["command": "pwd"],
            context: context
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?[AssistToolDataKey.path], subDir.path)
        XCTAssertTrue(result.output.contains("sub_folder"))
    }

    func testTerminalToolExplicitWorkingDirectory() async throws {
        let subDir = tempDir.appendingPathComponent("custom_dir")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let context = AssistContext(workspaceRoot: tempDir)
        let tool = AssistTerminalTool()
        let result = try await tool.execute(
            input: [
                "command": "pwd",
                "workingDirectory": "custom_dir"
            ],
            context: context
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?[AssistToolDataKey.path], subDir.path)
        XCTAssertTrue(result.output.contains("custom_dir"))
    }

    func testTerminalToolBlocksForbiddenCommands() async throws {
        let tool = AssistTerminalTool()
        let context = AssistContext(workspaceRoot: tempDir)

        let forbiddenCommands = [
            "sudo whoami",
            "rm -rf /",
            "rm -fr /",
            "rm -rf ~",
            "rm -rf .",
            "rm -rf ..",
            "rm -rf *",
            "diskutil eraseDisk APFS Test /dev/disk9",
            "mkfs.ext4 /dev/sda1",
            "dd if=/dev/zero of=/dev/null",
            "shutdown -h now",
            ":(){ :|:& };:"
        ]

        for cmd in forbiddenCommands {
            let result = try await tool.execute(input: ["command": cmd], context: context)
            XCTAssertFalse(result.success, "Command should have been blocked: \(cmd)")
            XCTAssertEqual(result.toolErrorCode, .permissionDenied)
            XCTAssertTrue(result.output.contains("Security Error"))
        }
    }

    func testTerminalToolRejectsOutsideWorkspaceWorkingDirectory() async throws {
        let outsideDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDir) }

        let tool = AssistTerminalTool()
        let context = AssistContext(workspaceRoot: tempDir)

        let result = try await tool.execute(
            input: [
                "command": "pwd",
                "workingDirectory": outsideDir.path
            ],
            context: context
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.toolErrorCode, .permissionDenied)
    }

    func testTerminalToolNonzeroExitCode() async throws {
        let tool = AssistTerminalTool()
        let context = AssistContext(workspaceRoot: tempDir)

        let result = try await tool.execute(
            input: ["command": "exit 42"],
            context: context
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.exitCode, 42)
        XCTAssertEqual(result.data?[AssistToolDataKey.exitCode], "42")
        XCTAssertEqual(result.toolErrorCode, .executionFailed)
        XCTAssertTrue(result.output.contains("failed with exit code 42"))
    }

    func testTerminalToolTimeoutHandling() async throws {
        let tool = AssistTerminalTool()
        let context = AssistContext(workspaceRoot: tempDir)

        let result = try await tool.execute(
            input: [
                "command": "sleep 10",
                "timeout": 1.0
            ],
            context: context
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.toolErrorCode, .timeout)
        XCTAssertTrue(result.output.contains("timed out"))
    }

    func testTerminalToolOutputTruncation() async throws {
        let tool = AssistTerminalTool()
        let context = AssistContext(workspaceRoot: tempDir)

        // Generate 50,000 characters
        let result = try await tool.execute(
            input: ["command": "python3 -c 'print(\"A\" * 50000)'"],
            context: context
        )

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("[Output truncated: showing first") && result.output.contains("characters"))
        XCTAssertEqual(result.data?[AssistToolDataKey.stdout]?.contains("[Output truncated"), true)
    }

    // MARK: - AssistWorkingDirectoryStore & dir_cd / dir_pwd Tests

    func testWorkingDirectoryStorePreservesCwdAcrossTools() async throws {
        let subDir = tempDir.appendingPathComponent("deep_workspace")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let sessionId = UUID()
        let context = AssistContext(sessionId: sessionId, workspaceRoot: tempDir)

        let cdTool = AssistChangeDirectoryTool()
        let cdResult = try await cdTool.execute(input: ["path": "deep_workspace"], context: context)
        XCTAssertTrue(cdResult.success)
        XCTAssertEqual(cdResult.data?["path"], subDir.path)

        // Pwd tool test
        let pwdTool = AssistPrintWorkingDirectoryTool()
        let pwdResult = try await pwdTool.execute(input: [:], context: context)
        XCTAssertTrue(pwdResult.success)
        XCTAssertEqual(pwdResult.data?["path"], subDir.path)

        // Verify stored in AssistWorkingDirectoryStore
        let stored = AssistWorkingDirectoryStore.shared.currentDirectory(for: sessionId)
        XCTAssertEqual(stored?.path, subDir.path)

        // New context with same sessionId should restore working directory
        let newContext = AssistContext(sessionId: sessionId, workspaceRoot: tempDir)
        XCTAssertEqual(newContext.fileSystem.currentDirectory.path, subDir.path)

        // Terminal run should default to stored directory
        let terminalTool = AssistTerminalTool()
        let termResult = try await terminalTool.execute(input: ["command": "pwd"], context: newContext)
        XCTAssertTrue(termResult.success)
        XCTAssertEqual(termResult.data?[AssistToolDataKey.path], subDir.path)
    }

    // MARK: - AssistProjectInspectTool Tests

    func testProjectInspectGitStatusAndDiff() async throws {
        let tool = AssistProjectInspectTool()
        let context = AssistContext(workspaceRoot: tempDir)

        // Not a git repo initially
        let statusResult = try await tool.execute(input: ["operation": "git_status"], context: context)
        XCTAssertTrue(statusResult.success)
        XCTAssertTrue(statusResult.output.contains("Not a git repository"))

        // Initialize git repo in tempDir
        let initProcess = Process()
        initProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        initProcess.arguments = ["init"]
        initProcess.currentDirectoryURL = tempDir
        try initProcess.run()
        initProcess.waitUntilExit()

        let gitStatusResult = try await tool.execute(input: ["operation": "git_status"], context: context)
        XCTAssertTrue(gitStatusResult.success)
        XCTAssertTrue(gitStatusResult.output.contains("Git Branch") || gitStatusResult.output.contains("clean"))

        // Test git_diff
        let diffResult = try await tool.execute(input: ["operation": "git_diff"], context: context)
        XCTAssertTrue(diffResult.success)
    }

    func testProjectInspectFindSymbolReferences() async throws {
        let tool = AssistProjectInspectTool()
        let file = tempDir.appendingPathComponent("Example.swift")
        let content = """
        struct MySpecialUniqueType {
            let value: Int
        }
        func calculate(item: MySpecialUniqueType) -> Int {
            return item.value
        }
        """
        try content.write(to: file, atomically: true, encoding: .utf8)

        let context = AssistContext(workspaceRoot: tempDir)
        let result = try await tool.execute(
            input: [
                "operation": "find_symbol_references",
                "symbol": "MySpecialUniqueType"
            ],
            context: context
        )

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("Example.swift"))
        XCTAssertTrue(result.output.contains("MySpecialUniqueType"))
    }

    func testProjectInspectXcodeTargetsAndSPM() async throws {
        let tool = AssistProjectInspectTool()
        // Run against Perspective-Studio repository workspace
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        let context = AssistContext(workspaceRoot: repoRoot)

        let xcodeResult = try await tool.execute(input: ["operation": "xcode_targets"], context: context)
        XCTAssertTrue(xcodeResult.success)
        XCTAssertTrue(xcodeResult.output.contains("Locally"))

        let spmResult = try await tool.execute(input: ["operation": "spm_packages"], context: context)
        XCTAssertTrue(spmResult.success)

        // Also test empty workspace without .xcodeproj
        let emptyContext = AssistContext(workspaceRoot: tempDir)
        let emptyResult = try await tool.execute(input: ["operation": "xcode_targets"], context: emptyContext)
        XCTAssertTrue(emptyResult.success)
        XCTAssertTrue(emptyResult.output.contains("No .xcodeproj found"))
    }

    // MARK: - Registry Registration Tests

    func testRegistryContainsNewTools() {
        let registry = ToolsRegistry.shared

        XCTAssertNotNil(registry.tool(for: "use_terminal"), "use_terminal must be registered")
        XCTAssertNotNil(registry.tool(for: "terminal_run"), "terminal_run alias must be registered")
        XCTAssertNotNil(registry.tool(for: "project_inspect"), "project_inspect must be registered")
        XCTAssertNotNil(registry.tool(for: "dir_pwd"), "dir_pwd must be registered")
        XCTAssertNotNil(registry.tool(for: "dir_cd"), "dir_cd must be registered")
    }
}
