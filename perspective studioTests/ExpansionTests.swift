import XCTest
@testable import perspective_studio

/// Tests for the expansion's pure logic: download validation shape, manifest
/// round-trip, knowledge-base chunking/retrieval, the tool expression parser,
/// tool-call parsing, and routing. These intentionally avoid the network and
/// the MLX engine so they can run anywhere the app builds.
final class ExpansionTests: XCTestCase {

    // MARK: - Download validation

    func testMissingModelIsNotInstalled() {
        let result = ModelArtifactValidator.validate(modelID: "perspective-test/definitely-not-downloaded-xyz")
        XCTAssertFalse(result.isComplete)
        XCTAssertFalse(result.issues.isEmpty)
        XCTAssertFalse(ModelArtifactValidator.isInstalled(modelID: "perspective-test/definitely-not-downloaded-xyz"))
    }

    func testManifestRoundTrip() throws {
        let manifest = HFModelManifest(
            modelID: "mlx-community/example",
            revision: "abc123",
            files: [
                HFRepoFile(path: "config.json", size: 783, etag: "e3c0e7", sha256: nil),
                HFRepoFile(path: "model.safetensors", size: 278_064_920, etag: "ddffab", sha256: "ddffab"),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(HFModelManifest.self, from: data)
        XCTAssertEqual(decoded.modelID, manifest.modelID)
        XCTAssertEqual(decoded.files.count, 2)
        XCTAssertEqual(decoded.totalBytes, 783 + 278_064_920)
    }

    func testModelDirectoryMatchesEngineCacheLayout() {
        // The engine (MLX Swift LM's defaultHubApi) loads from
        // ~/Library/Caches/models/<org>/<name> — downloads must land there.
        let dir = HFHubCache.modelDirectory(for: "mlx-community/Qwen2.5-0.5B-Instruct-4bit")
        XCTAssertTrue(dir.path.hasSuffix("Library/Caches/models/mlx-community/Qwen2.5-0.5B-Instruct-4bit"), dir.path)
        let metadata = HFHubCache.metadataURL(for: "mlx-community/Qwen2.5-0.5B-Instruct-4bit", relativePath: "config.json")
        XCTAssertTrue(metadata.path.hasSuffix(".cache/huggingface/download/config.json.metadata"), metadata.path)
    }

    func testHubMetadataFormatMatchesEngineExpectations() {
        // HubApi.readDownloadMetadata requires >= 3 lines and a numeric
        // timestamp; offline mode additionally hash-checks LFS etags.
        let content = HubDownloadMetadata.content(
            commitHash: "a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3",
            etag: "ddffab9cbc7bf6dde941c6724841eeca8981fcfa81ca20ff8efff1396326d153",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let lines = content.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3")
        XCTAssertEqual(lines[1], "ddffab9cbc7bf6dde941c6724841eeca8981fcfa81ca20ff8efff1396326d153")
        XCTAssertNotNil(Double(lines[2]))
    }

    // MARK: - Knowledge base

    func testChunkingProducesOverlapAndCoversText() {
        let text = (0..<200).map { "word\($0)" }.joined(separator: " ")
        let chunks = KnowledgeBaseStore.chunkText(text, chunkSize: 200, overlap: 40)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty })
    }

    func testRetrievalFindsRelevantPassageWithCitation() {
        let document = KBDocument(title: "Gardening Notes", sourcePath: "/tmp/garden.md", chunkCount: 2, characterCount: 100)
        let chunks = [
            KBChunk(documentID: document.id, index: 0, text: "Tomatoes need full sun and regular watering in summer."),
            KBChunk(documentID: document.id, index: 1, text: "Compilers parse source code into an abstract syntax tree."),
        ]
        let results = KnowledgeBaseStore.search(query: "watering tomatoes", chunks: chunks, documents: [document])
        XCTAssertEqual(results.first?.chunk.index, 0)
        XCTAssertEqual(results.first?.citation, "[Gardening Notes · passage 1]")
    }

    // MARK: - Tools

    @MainActor
    func testArithmeticEvaluator() throws {
        XCTAssertEqual(try ArithmeticExpression.evaluate("2 + 3 * 4"), 14, accuracy: 0.0001)
        XCTAssertEqual(try ArithmeticExpression.evaluate("(2 + 3) * 4"), 20, accuracy: 0.0001)
        XCTAssertEqual(try ArithmeticExpression.evaluate("2 ^ 10"), 1024, accuracy: 0.0001)
        XCTAssertEqual(try ArithmeticExpression.evaluate("sqrt(144) + abs(-3)"), 15, accuracy: 0.0001)
        XCTAssertThrowsError(try ArithmeticExpression.evaluate("2 + "))
        XCTAssertThrowsError(try ArithmeticExpression.evaluate("__import__('os')"))
    }

    func testToolCallParsing() {
        let text = """
        I should compute that.
        TOOL_CALL {"tool": "calculator", "arguments": {"expression": "6 * 7"}}
        """
        let call = ToolCallingService.parseToolCall(in: text)
        XCTAssertEqual(call?.toolID, "calculator")
        XCTAssertEqual(call?.arguments["expression"], "6 * 7")
        XCTAssertNil(ToolCallingService.parseToolCall(in: "Just a normal answer."))
    }

    // MARK: - Routing

    @MainActor
    func testRoutingVisionRequiresVisionModel() {
        let textOnly = InstalledModel(id: "mlx-community/Qwen2.5-0.5B-Instruct-4bit", displayName: "Qwen2.5-0.5B-Instruct-4bit", author: "mlx-community", isVisual: false)
        XCTAssertNil(ModelRouter.route(task: .vision, installedModels: [textOnly], overrideModelID: nil))

        let vision = InstalledModel(id: "mlx-community/SmolVLM-Instruct", displayName: "SmolVLM-Instruct", author: "mlx-community", isVisual: true)
        let decision = ModelRouter.route(task: .vision, installedModels: [textOnly, vision], overrideModelID: nil)
        XCTAssertEqual(decision?.model.id, vision.id)
    }

    @MainActor
    func testRoutingManualOverrideWins() {
        let a = InstalledModel(id: "org/model-a", displayName: "model-a", author: "org", isVisual: false)
        let b = InstalledModel(id: "org/model-b-coder", displayName: "model-b-coder", author: "org", isVisual: false)
        let decision = ModelRouter.route(task: .code, installedModels: [a, b], overrideModelID: a.id)
        XCTAssertEqual(decision?.model.id, a.id)
        XCTAssertTrue(decision?.isManualOverride == true)
    }
}
