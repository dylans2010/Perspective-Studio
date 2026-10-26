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

    func testFileSearchToolFilenameAndContentMatches() async throws {
        let viewsDir = tempDir.appendingPathComponent("Locally/Views", isDirectory: true)
        try FileManager.default.createDirectory(at: viewsDir, withIntermediateDirectories: true)
        let mainViewFile = viewsDir.appendingPathComponent("AssistMainView.swift")
        try "struct AssistMainView: View {\n    var body: some View { Text(\"AssistMain\") }\n}".write(to: mainViewFile, atomically: true, encoding: .utf8)

        let context = AssistContext(workspaceRoot: tempDir)
        let tool = FileSearchAssistTool()

        // 1. Search by filename
        let nameResult = try await tool.execute(input: ["query": "AssistMainView", "searchType": "filename"], context: context)
        XCTAssertTrue(nameResult.success)
        XCTAssertTrue(nameResult.output.contains("[Filename match]"))
        XCTAssertTrue(nameResult.output.contains("AssistMainView.swift"))

        // 2. Search by content
        let contentResult = try await tool.execute(input: ["query": "AssistMain", "searchType": "content"], context: context)
        XCTAssertTrue(contentResult.success)
        XCTAssertTrue(contentResult.output.contains("[Content match]"))
        XCTAssertTrue(contentResult.output.contains("AssistMainView.swift:2:"))

        // 3. Search both
        let bothResult = try await tool.execute(input: ["query": "AssistMainView"], context: context)
        XCTAssertTrue(bothResult.success)
        XCTAssertTrue(bothResult.output.contains("AssistMainView.swift"))
    }

    func testFileSearchFilenameMatchNotCrowdedOutByContentMatches() async throws {
        // Regression test for the reported AssistMainView-style failure:
        // with a small budget and many files that merely *mention* the
        // target name, a "both" search must still surface the file itself.
        // The old single-bucket implementation let content hits enumerated
        // first consume the whole budget, so the filename match could be
        // dropped entirely depending on enumeration order.
        let viewsDir = tempDir.appendingPathComponent("Views", isDirectory: true)
        try FileManager.default.createDirectory(at: viewsDir, withIntermediateDirectories: true)
        let target = viewsDir.appendingPathComponent("AssistMainView.swift")
        try "struct AssistMainView: View { var body: some View { Text(\"x\") } }".write(to: target, atomically: true, encoding: .utf8)
        for index in 0..<10 {
            let decoy = tempDir.appendingPathComponent("Decoy\(index).swift")
            try "/// References AssistMainView in a comment.\nlet ref = \"AssistMainView\"".write(to: decoy, atomically: true, encoding: .utf8)
        }

        let context = AssistContext(workspaceRoot: tempDir)
        let tool = FileSearchAssistTool()
        let result = try await tool.execute(input: ["query": "AssistMainView", "maxResults": 3], context: context)
        XCTAssertTrue(result.success)
        // The filename match must be present and first, whatever order
        // the filesystem enumerated the decoys in.
        XCTAssertTrue(result.output.contains("[Filename match] Views/AssistMainView.swift"), "Output was: \(result.output)")
        XCTAssertTrue(result.output.hasPrefix("[Filename match] Views/AssistMainView.swift"), "Filename match must lead the output, got: \(result.output)")
        XCTAssertEqual(result.data?["filenameCount"], "1")
    }

    func testFileSearchToolDirectoryPruningAndIncludeIgnored() async throws {
        // Create files in build and .git directories
        let buildDir = tempDir.appendingPathComponent("build/DerivedData", isDirectory: true)
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        let buildArtifact = buildDir.appendingPathComponent("Artifact.swift")
        try "let buildArtifactSecret = 123".write(to: buildArtifact, atomically: true, encoding: .utf8)

        let gitDir = tempDir.appendingPathComponent(".git/objects", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        let gitObj = gitDir.appendingPathComponent("GitSecret.swift")
        try "let gitSecret = 456".write(to: gitObj, atomically: true, encoding: .utf8)

        let context = AssistContext(workspaceRoot: tempDir)
        let tool = FileSearchAssistTool()

        // Default search should skip build & .git
        let defaultResult = try await tool.execute(input: ["query": "buildArtifactSecret"], context: context)
        XCTAssertTrue(defaultResult.success)
        XCTAssertTrue(defaultResult.output.contains("No matches for 'buildArtifactSecret'"))

        // When includeIgnored: true, it should find it
        let ignoredResult = try await tool.execute(input: ["query": "buildArtifactSecret", "includeIgnored": true], context: context)
        XCTAssertTrue(ignoredResult.success)
        XCTAssertTrue(ignoredResult.output.contains("Artifact.swift"))
    }

    func testReadFileToolNonExistentFileReturnsNotFound() async throws {
        let context = AssistContext(workspaceRoot: tempDir)
        let tool = AssistReadFileTool()
        let result = try await tool.execute(input: ["path": "does_not_exist.swift"], context: context)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.toolErrorCode, .notFound)
        XCTAssertTrue(result.output.contains("File does not exist"))
    }

    func testReadFileToolDirectoryReturnsInvalidInput() async throws {
        let dir = tempDir.appendingPathComponent("subfolder", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let context = AssistContext(workspaceRoot: tempDir)
        let tool = AssistReadFileTool()
        let result = try await tool.execute(input: ["path": "subfolder"], context: context)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.toolErrorCode, .invalidInput)
        XCTAssertTrue(result.output.contains("is a directory, not a file"))
    }

    func testReadFileToolEmptyFile() async throws {
        let emptyFile = tempDir.appendingPathComponent("empty.txt")
        try "".write(to: emptyFile, atomically: true, encoding: .utf8)

        let context = AssistContext(workspaceRoot: tempDir)
        let tool = AssistReadFileTool()
        let result = try await tool.execute(input: ["path": "empty.txt"], context: context)
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("File is empty: empty.txt"))
        XCTAssertEqual(result.data?["totalLines"], "0")
    }

    func testReadFileToolLineRangesAndClamping() async throws {
        let file = tempDir.appendingPathComponent("lines.txt")
        try "Line1\nLine2\nLine3\nLine4\nLine5".write(to: file, atomically: true, encoding: .utf8)

        let context = AssistContext(workspaceRoot: tempDir)
        let tool = AssistReadFileTool()

        // Sliced lines 2 to 4
        let rangeResult = try await tool.execute(input: ["path": "lines.txt", "lines": ["start": 2, "end": 4]], context: context)
        XCTAssertTrue(rangeResult.success)
        XCTAssertTrue(rangeResult.output.contains("lines 2-4 of 5"))
        XCTAssertTrue(rangeResult.output.contains("2: Line2"))
        XCTAssertTrue(rangeResult.output.contains("3: Line3"))
        XCTAssertTrue(rangeResult.output.contains("4: Line4"))
        XCTAssertFalse(rangeResult.output.contains("1: Line1"))
        XCTAssertFalse(rangeResult.output.contains("5: Line5"))

        // Out of range start
        let invalidStartResult = try await tool.execute(input: ["path": "lines.txt", "lines": ["start": 10, "end": 12]], context: context)
        XCTAssertFalse(invalidStartResult.success)
        XCTAssertEqual(invalidStartResult.toolErrorCode, .invalidInput)
    }

    func testReadFileToolBinaryFileDetected() async throws {
        let binFile = tempDir.appendingPathComponent("image.png")
        let binaryBytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        try Data(binaryBytes).write(to: binFile)

        let context = AssistContext(workspaceRoot: tempDir)
        let tool = AssistReadFileTool()
        let result = try await tool.execute(input: ["path": "image.png"], context: context)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.toolErrorCode, .invalidInput)
        XCTAssertTrue(result.output.contains("binary or unsupported file"))
    }

    func testTreeViewToolPrunesSkippedDirectoriesByDefault() async throws {
        let buildDir = tempDir.appendingPathComponent("build/SubDir", isDirectory: true)
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        let srcDir = tempDir.appendingPathComponent("Sources/App", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try "print()".write(to: srcDir.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)

        let context = AssistContext(workspaceRoot: tempDir)
        let tool = AssistTreeViewTool()
        let result = try await tool.execute(input: ["path": "."], context: context)

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("Sources"))
        XCTAssertTrue(result.output.contains("App.swift"))
        XCTAssertFalse(result.output.contains("SubDir"))
    }

    func testReadDirectoryToolShowsCountsAndSizes() async throws {
        let dir = tempDir.appendingPathComponent("details", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "hello".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let sub = dir.appendingPathComponent("nested_folder", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let context = AssistContext(workspaceRoot: tempDir)
        let tool = AssistReadDirectoryTool()
        let result = try await tool.execute(input: ["path": "details"], context: context)

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("Directory details (2 entries):"))
        XCTAssertTrue(result.output.contains("a.txt"))
        XCTAssertTrue(result.output.contains("nested_folder/"))
        XCTAssertTrue(result.output.contains("1 files, 1 directories"))
    }

    func testFileMetadataToolAttributes() async throws {
        let file = tempDir.appendingPathComponent("meta.swift")
        try "import Foundation".write(to: file, atomically: true, encoding: .utf8)

        let context = AssistContext(workspaceRoot: tempDir)
        let tool = AssistFileMetadataTool()
        let result = try await tool.execute(input: ["path": "meta.swift"], context: context)

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("Metadata for meta.swift:"))
        XCTAssertTrue(result.output.contains("Extension: swift"))
        XCTAssertTrue(result.output.contains("Is directory: false"))
        XCTAssertEqual(result.data?["isDirectory"], "false")
    }

    func testAssistWorkspaceScanPruning() {
        XCTAssertTrue(AssistWorkspaceScan.skippedDirs.contains(".git"))
        XCTAssertTrue(AssistWorkspaceScan.skippedDirs.contains(".build"))
        XCTAssertTrue(AssistWorkspaceScan.skippedDirs.contains("build"))
        XCTAssertTrue(AssistWorkspaceScan.skippedDirs.contains("DerivedData"))
        XCTAssertTrue(AssistWorkspaceScan.skippedDirs.contains("Pods"))
        XCTAssertTrue(AssistWorkspaceScan.skippedDirs.contains("node_modules"))
        XCTAssertTrue(AssistWorkspaceScan.skippedDirs.contains(".venv"))
        XCTAssertTrue(AssistWorkspaceScan.skippedDirs.contains("xcuserdata"))
    }
}
