import XCTest
@testable import Locally

final class SystemAssetsManagerTests: XCTestCase {
    @MainActor
    func testAvailableAssetsAndIndexGeneration() async {
        let manager = SystemAssetsManager.shared
        await manager.scanAssets()

        let assets = manager.availableAssets()
        XCTAssertFalse(assets.isEmpty)
        XCTAssertTrue(assets.contains(where: { $0.id == "system_agent_instructions" }))
        XCTAssertTrue(assets.contains(where: { $0.id == "tool_usage_guidelines" }))
        XCTAssertTrue(assets.contains(where: { $0.id == "coding_standards" }))
        XCTAssertTrue(assets.contains(where: { $0.id == "response_style" }))

        let index = manager.generatePromptIndex()
        XCTAssertTrue(index.contains("[System Assets Index]"))
        XCTAssertTrue(index.contains("system_agent_instructions"))
        XCTAssertTrue(index.contains("tool_usage_guidelines"))
        XCTAssertTrue(index.contains("coding_standards"))
        XCTAssertTrue(index.contains("response_style"))
    }

    @MainActor
    func testFetchAssetContent() async {
        let manager = SystemAssetsManager.shared
        await manager.scanAssets()

        let instructions = manager.fetchAssetContent(named: "system_agent_instructions")
        XCTAssertNotNil(instructions)
        XCTAssertTrue(instructions?.contains("System Agent Instructions") == true)

        let coding = manager.fetchAssetContent(named: "coding_standards.md")
        XCTAssertNotNil(coding)
        XCTAssertTrue(coding?.contains("Coding Standards") == true)

        let tools = manager.fetchAssetContent(named: "TOOL_USAGE_GUIDELINES")
        XCTAssertNotNil(tools)
        XCTAssertTrue(tools?.contains("Tool Usage Guidelines") == true)

        let style = manager.fetchAssetContent(named: "Response Style & Formatting")
        XCTAssertNotNil(style)
        XCTAssertTrue(style?.contains("Response Style") == true)
    }
}
