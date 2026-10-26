import XCTest
@testable import Locally

@MainActor
final class AssistToolOutputRepairTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("assist-tool-repair-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    func testReadFileToolIncludesContentInOutput() async throws {
        let filePath = tempDir.appendingPathComponent("example.txt")
        let fileContent = "Alpha\nBeta\nGamma"
        try fileContent.write(to: filePath, atomically: true, encoding: .utf8)

        let context = AssistContext(workspaceRoot: tempDir)
        let tool = AssistReadFileTool()
        let result = try await tool.execute(input: ["path": "example.txt"], context: context)

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("Successfully read file: example.txt (lines 1-3 of 3):"))
        XCTAssertTrue(result.output.contains("1: Alpha"))
        XCTAssertTrue(result.output.contains("2: Beta"))
        XCTAssertTrue(result.output.contains("3: Gamma"))
    }

    func testReadDirectoryToolIncludesEntriesInOutput() async throws {
        let subDir = tempDir.appendingPathComponent("subfolder")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let file = tempDir.appendingPathComponent("sample.txt")
        try "test".write(to: file, atomically: true, encoding: .utf8)

        let context = AssistContext(workspaceRoot: tempDir)
        let tool = AssistReadDirectoryTool()
        let result = try await tool.execute(input: ["path": "."], context: context)

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("Directory . (2 entries):"))
        XCTAssertTrue(result.output.contains("sample.txt"))
        XCTAssertTrue(result.output.contains("subfolder/"))
    }

    func testReadDirectoryToolEmptyDirectoryOutput() async throws {
        let emptyDir = tempDir.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)

        let context = AssistContext(workspaceRoot: tempDir)
        let tool = AssistReadDirectoryTool()
        let result = try await tool.execute(input: ["path": "empty"], context: context)

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("Directory empty (0 entries):"))
        XCTAssertTrue(result.output.contains("(directory is empty)"))
    }

    func testTreeViewToolIncludesTreeInOutput() async throws {
        let nestedDir = tempDir.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        let file = nestedDir.appendingPathComponent("nested_file.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        let context = AssistContext(workspaceRoot: tempDir)
        let tool = AssistTreeViewTool()
        let result = try await tool.execute(input: ["path": "."], context: context)

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("Project Tree for \(tempDir.lastPathComponent):"))
        XCTAssertTrue(result.output.contains("nested"))
        XCTAssertTrue(result.output.contains("nested_file.txt"))
    }

    func testSearchToolIncludesFormattedResultsAndNoMatchesMessage() async throws {
        let file = tempDir.appendingPathComponent("searchable.txt")
        try "TargetPatternInThisFile\nOtherLine".write(to: file, atomically: true, encoding: .utf8)

        let context = AssistContext(workspaceRoot: tempDir)
        let tool = AssistSearchTool()

        // Match case
        let matchResult = try await tool.execute(input: ["pattern": "TargetPatternInThisFile"], context: context)
        XCTAssertTrue(matchResult.success)
        XCTAssertTrue(matchResult.output.contains("Search results for 'TargetPatternInThisFile':"))
        XCTAssertTrue(matchResult.output.contains("searchable.txt:"))
        XCTAssertTrue(matchResult.output.contains("TargetPatternInThisFile"))

        // No match case
        let noMatchResult = try await tool.execute(input: ["pattern": "NonExistentString12345"], context: context)
        XCTAssertTrue(noMatchResult.success)
        XCTAssertTrue(noMatchResult.output.contains("No matches found"))
    }

    func testRegexSearchToolIncludesMatchLinesAndNoMatchesMessage() async throws {
        let file = tempDir.appendingPathComponent("regex_target.txt")
        try "foo123bar\nbaz456qux".write(to: file, atomically: true, encoding: .utf8)

        let context = AssistContext(workspaceRoot: tempDir)
        let tool = AssistRegexSearchTool()

        // Match case
        let matchResult = try await tool.execute(input: ["pattern": "foo\\d+bar"], context: context)
        XCTAssertTrue(matchResult.success)
        XCTAssertTrue(matchResult.output.contains("Regex search results for 'foo\\d+bar':"))
        XCTAssertTrue(matchResult.output.contains("regex_target.txt:1: foo123bar"))

        // No match case
        let noMatchResult = try await tool.execute(input: ["pattern": "missing_pattern_\\d+"], context: context)
        XCTAssertTrue(noMatchResult.success)
        XCTAssertTrue(noMatchResult.output.contains("No matches found"))
    }

    func testSymbolSearchToolIncludesMatchLinesAndNoMatchesMessage() async throws {
        let file = tempDir.appendingPathComponent("Symbols.swift")
        try """
        class PerspectiveService {
            func doPerspectiveAction() {}
        }
        """.write(to: file, atomically: true, encoding: .utf8)

        let context = AssistContext(workspaceRoot: tempDir)
        let tool = AssistSymbolSearchTool()

        // Match case
        let matchResult = try await tool.execute(input: ["symbol": "PerspectiveService"], context: context)
        XCTAssertTrue(matchResult.success)
        XCTAssertTrue(matchResult.output.contains("Symbol search results for 'PerspectiveService':"))
        XCTAssertTrue(matchResult.output.contains("class PerspectiveService"))

        // No match case
        let noMatchResult = try await tool.execute(input: ["symbol": "UnusedTypeXYZ"], context: context)
        XCTAssertTrue(noMatchResult.success)
        XCTAssertTrue(noMatchResult.output.contains("No matches found"))
    }
}
