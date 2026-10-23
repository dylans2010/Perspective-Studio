import XCTest
@testable import Locally

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Tests for the built-in Apple model integration. They avoid running the
/// model itself: availability differs per Mac, so these cover the wiring the
/// app owns — identity, backend selection, and the tool bridge.
@MainActor
final class AppleFoundationModelTests: XCTestCase {

    func testAppleModelIdentityAndDescriptor() {
        XCTAssertTrue(AppleFoundationModel.isAppleModel(AppleFoundationModel.modelID))
        XCTAssertFalse(AppleFoundationModel.isAppleModel(nil))
        XCTAssertFalse(AppleFoundationModel.isAppleModel("mlx-community/gemma-2-2b-it-4bit"))

        let descriptor = AppleFoundationModel.descriptor
        XCTAssertEqual(descriptor.id, AppleFoundationModel.modelID)
        XCTAssertEqual(descriptor.displayName, "Apple Intelligence")
        XCTAssertFalse(descriptor.isVisual)
    }

    func testAvailabilityAlwaysExplainsItself() {
        XCTAssertTrue(AppleModelAvailability.available.isAvailable)
        XCTAssertFalse(AppleModelAvailability.unavailable("Turn it on in Settings.").isAvailable)
        XCTAssertFalse(AppleModelAvailability.unsupportedSystem.isAvailable)

        for availability: AppleModelAvailability in [
            .available,
            .unavailable("Turn it on in Settings."),
            .unsupportedSystem
        ] {
            XCTAssertFalse(availability.explanation.isEmpty)
        }

        XCTAssertNil(AppleModelAvailability.available.shortStatus)
        XCTAssertEqual(AppleModelAvailability.unavailable("x").shortStatus, "Unavailable")
        XCTAssertEqual(AppleModelAvailability.unsupportedSystem.shortStatus, "Requires macOS 26")
    }

    func testBackendSelectionFollowsModelID() {
        XCTAssertEqual(
            InferenceBackends.backend(forModelID: AppleFoundationModel.modelID).backendID,
            AppleFoundationModel.backendID
        )
        XCTAssertEqual(
            InferenceBackends.backend(forModelID: "mlx-community/gemma-2-2b-it-4bit").backendID,
            "mlx"
        )
        XCTAssertEqual(InferenceBackends.backend(forModelID: nil).backendID, "mlx")
    }

    func testOfferedAgentToolsAreRegistered() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Foundation Models requires macOS 26 or later.")
        }
        for toolID in FoundationModelAgentRunner.offeredToolIDs {
            XCTAssertNotNil(ToolsRegistry.shared.tool(for: toolID), "Agent tool '\(toolID)' is not registered")
        }
    }

    func testBridgedToolSchemasBuildForEveryOfferedTool() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Foundation Models requires macOS 26 or later.")
        }
        let context = AssistContext(workspaceRoot: URL.documentsDirectory)
        for toolID in FoundationModelAgentRunner.offeredToolIDs {
            guard let tool = ToolsRegistry.shared.tool(for: toolID) else { continue }
            XCTAssertNoThrow(
                try AssistToolBridge(tool: tool, context: context),
                "Could not build a Foundation Models schema for '\(toolID)'"
            )
        }
    }

    func testGeneratedToolArgumentsBecomeToolArguments() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Foundation Models requires macOS 26 or later.")
        }
        let content = GeneratedContent(properties: [
            "asset_id": "coding_standards",
            "limit": 5,
            "verbose": true
        ])

        let arguments = AssistToolBridge.argumentsDictionary(from: content)

        XCTAssertEqual(arguments["asset_id"] as? String, "coding_standards")
        XCTAssertEqual(arguments["limit"] as? Int, 5)
        XCTAssertEqual(arguments["verbose"] as? Bool, true)
    }

    func testStreamingThroughTheBackendProducesTextAndMetrics() async throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Foundation Models requires macOS 26 or later.")
        }
        guard AppleFoundationModel.isAvailable else {
            throw XCTSkip("Apple Intelligence is not enabled on this Mac.")
        }

        let backend = InferenceBackends.backend(forModelID: AppleFoundationModel.modelID)
        _ = try await backend.load(model: AppleFoundationModel.descriptor)

        var text = ""
        var metrics: GenerationMetrics?
        let stream = try backend.stream(
            prompt: "Reply with exactly: ready",
            systemPrompt: "Answer with one short word."
        )
        for try await event in stream {
            switch event {
            case .token(let token):
                text += token
            case .finished(let finalMetrics):
                metrics = finalMetrics
            }
        }

        XCTAssertFalse(text.isEmpty)
        XCTAssertNotNil(metrics)
        XCTAssertGreaterThan(metrics?.totalSeconds ?? 0, 0)
    }

    func testNativeToolCallRunsTheRegisteredTool() async throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Foundation Models requires macOS 26 or later.")
        }
        guard AppleFoundationModel.isAvailable else {
            throw XCTSkip("Apple Intelligence is not enabled on this Mac.")
        }

        let context = AssistContext(workspaceRoot: URL.documentsDirectory)
        let calculator = try XCTUnwrap(ToolsRegistry.shared.tool(for: "calculator"))
        let bridge = try AssistToolBridge(tool: calculator, context: context)
        let session = LanguageModelSession(
            tools: [bridge],
            instructions: "You must use the calculator tool for arithmetic. Never compute in your head."
        )

        let response = try await session.respond(to: "What is 12 * 7?")

        XCTAssertTrue(response.content.localizedStandardContains("84"), "Unexpected answer: \(response.content)")
    }

    func testSystemAssetLookupBridgeKeepsToolIdentity() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Foundation Models requires macOS 26 or later.")
        }
        let tool = SystemAssetLookupAssistTool()
        let bridge = try AssistToolBridge(
            tool: tool,
            context: AssistContext(workspaceRoot: URL.documentsDirectory)
        )

        XCTAssertEqual(bridge.toolID, tool.id)
        XCTAssertEqual(bridge.name, tool.name)
        XCTAssertEqual(bridge.description, tool.description)
    }
}
