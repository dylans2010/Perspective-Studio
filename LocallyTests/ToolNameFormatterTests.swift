import XCTest
@testable import Locally

@MainActor
final class ToolNameFormatterTests: XCTestCase {
    func testTaskObjectiveExamples() {
        XCTAssertEqual(ToolNameFormatter.format("create_file"), "Creating File")
        XCTAssertEqual(ToolNameFormatter.format("file_create"), "Creating File")
        XCTAssertEqual(ToolNameFormatter.format("file_append"), "Appending to File")
        XCTAssertEqual(ToolNameFormatter.format("search_skills"), "Searching Skills")
        XCTAssertEqual(ToolNameFormatter.format("read_file"), "Reading File")
        XCTAssertEqual(ToolNameFormatter.format("workspace_search"), "Searching Workspace")
        XCTAssertEqual(ToolNameFormatter.format("hardware_info"), "Checking Mac Hardware Info")
        XCTAssertEqual(ToolNameFormatter.format("calculator"), "Calculating Expression")
        XCTAssertEqual(ToolNameFormatter.format("date_time"), "Checking Date & Time")
    }

    func testDynamicGrammaticalInflections() {
        // Leading verb
        XCTAssertEqual(ToolNameFormatter.format("audit_access_levels"), "Auditing Access Levels")
        XCTAssertEqual(ToolNameFormatter.format("run_command"), "Running Command")
        XCTAssertEqual(ToolNameFormatter.format("generate_image"), "Generating Image")
        XCTAssertEqual(ToolNameFormatter.format("delete_file"), "Deleting File")
        XCTAssertEqual(ToolNameFormatter.format("inspect_network"), "Inspecting Network")
        XCTAssertEqual(ToolNameFormatter.format("validate_schema"), "Validating Schema")

        // Trailing verb
        XCTAssertEqual(ToolNameFormatter.format("skills_search"), "Searching Skills")
        XCTAssertEqual(ToolNameFormatter.format("file_read"), "Reading File")
        XCTAssertEqual(ToolNameFormatter.format("code_symbol_index"), "Indexing Code Symbols")
    }

    func testCaseVariations() {
        // camelCase
        XCTAssertEqual(ToolNameFormatter.format("createFile"), "Creating File")
        XCTAssertEqual(ToolNameFormatter.format("fileCreate"), "Creating File")
        XCTAssertEqual(ToolNameFormatter.format("searchSkills"), "Searching Skills")
        XCTAssertEqual(ToolNameFormatter.format("runCommand"), "Running Command")

        // kebab-case
        XCTAssertEqual(ToolNameFormatter.format("create-file"), "Creating File")
        XCTAssertEqual(ToolNameFormatter.format("file-append"), "Appending to File")
        XCTAssertEqual(ToolNameFormatter.format("workspace-search"), "Searching Workspace")
    }

    func testFallbackToUsingTitle() {
        XCTAssertEqual(ToolNameFormatter.format("weather_forecast"), "Using Weather Forecast")
        XCTAssertEqual(ToolNameFormatter.format("custom_widget_renderer"), "Using Custom Widget Renderer")
        XCTAssertEqual(ToolNameFormatter.format("assistantTool"), "Using Assistant Tool")
    }

    func testNeverExposesTechnicalIdentifiers() {
        let tools = [
            "create_file", "file_append", "search_skills", "read_file",
            "audit_access_levels", "run_command", "generate_image",
            "custom_helper_tool", "xml_parser_node"
        ]

        for tool in tools {
            let formatted = ToolNameFormatter.format(tool)
            XCTAssertFalse(formatted.contains("_"), "Formatted string should never contain underscore: \(formatted)")
            XCTAssertFalse(formatted.contains("-"), "Formatted string should never contain hyphen: \(formatted)")
        }
    }

    func testCompletedTitles() {
        XCTAssertEqual(ToolNameFormatter.completedTitle(for: "create_file"), "Created File")
        XCTAssertEqual(ToolNameFormatter.completedTitle(for: "search_skills"), "Searched Skills")
        XCTAssertEqual(ToolNameFormatter.completedTitle(for: "file_append"), "Appended to File")
        XCTAssertEqual(ToolNameFormatter.completedTitle(for: "calculator"), "Calculated Expression")
    }

    func testFormatArgumentKeys() {
        XCTAssertEqual(ToolNameFormatter.formatArgumentKey("file_path"), "File Path")
        XCTAssertEqual(ToolNameFormatter.formatArgumentKey("query"), "Query")
        XCTAssertEqual(ToolNameFormatter.formatArgumentKey("target_dir"), "Target Dir")
        XCTAssertEqual(ToolNameFormatter.formatArgumentKey("api_key"), "API Key")
    }

    func testToolCallRecordDuration() {
        let record = ToolCallRecord(toolID: "create_file", duration: 0.42)
        XCTAssertEqual(record.formattedDuration, "0.4s")

        let fastRecord = ToolCallRecord(toolID: "calculator", duration: 0.02)
        XCTAssertEqual(fastRecord.formattedDuration, "<0.1s")
    }
}
