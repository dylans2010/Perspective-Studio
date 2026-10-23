import XCTest
import CryptoKit
@testable import Locally

/// The bundled Antigravity SDK is verified against its SHA-256 manifest,
/// and the loop-only policy (no executable model/tool runtime in the
/// bundle) is enforced by `AntigravitySDKBundle.status(directory:)`.
/// These tests build synthetic bundles in a temp folder and pin both.
final class AntigravitySDKBundleTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sdk-bundle-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func writeFile(_ relativePath: String, contents: String) {
        let url = tempDir.appendingPathComponent(relativePath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeManifest(files: [(path: String, contents: String)]) {
        let entries = files.map { file -> String in
            let digest = SHA256.hash(data: Data(file.contents.utf8)).map { String(format: "%02x", $0) }.joined()
            return "{\"path\": \"\(file.path)\", \"sha256\": \"\(digest)\", \"bytes\": \(file.contents.utf8.count)}"
        }
        let manifest = "{\"sdk\": \"google-antigravity\", \"version\": \"0.1.20\", \"files\": [\(entries.joined(separator: ", "))]}"
        writeFile("sdk-manifest.json", contents: manifest)
    }

    func testIntactBundleVerifies() {
        writeFile("google/antigravity/agent.py", contents: "# agent loop\n")
        writeFile("google/antigravity/types.py", contents: "# types\n")
        writeManifest(files: [
            ("google/antigravity/agent.py", "# agent loop\n"),
            ("google/antigravity/types.py", "# types\n")
        ])

        let status = AntigravitySDKBundle.status(directory: tempDir)
        XCTAssertTrue(status.isBundled)
        XCTAssertEqual(status.version, "0.1.20")
        XCTAssertEqual(status.fileCount, 2)
        XCTAssertTrue(status.integrityVerified)
        XCTAssertFalse(status.containsExecutableRuntime)
        XCTAssertTrue(status.isUsable)
    }

    func testTamperedFileFailsIntegrity() {
        writeFile("google/antigravity/agent.py", contents: "# agent loop\n")
        writeManifest(files: [("google/antigravity/agent.py", "# agent loop\n")])
        writeFile("google/antigravity/agent.py", contents: "# tampered\n")

        let status = AntigravitySDKBundle.status(directory: tempDir)
        XCTAssertFalse(status.integrityVerified)
        XCTAssertFalse(status.isUsable)
        XCTAssertFalse(status.issues.isEmpty)
    }

    func testMissingManifestCannotVerify() {
        writeFile("google/antigravity/agent.py", contents: "# agent loop\n")
        let status = AntigravitySDKBundle.status(directory: tempDir)
        XCTAssertTrue(status.isBundled)
        XCTAssertFalse(status.integrityVerified)
        XCTAssertFalse(status.isUsable)
    }

    func testExecutableRuntimeViolatesLoopOnlyPolicy() {
        writeFile("google/antigravity/agent.py", contents: "# agent loop\n")
        writeManifest(files: [("google/antigravity/agent.py", "# agent loop\n")])
        // The SDK's compiled model/tool runtime must never ship.
        writeFile("google/antigravity/bin/localharness", contents: "binary")

        let status = AntigravitySDKBundle.status(directory: tempDir)
        XCTAssertTrue(status.containsExecutableRuntime)
        XCTAssertFalse(status.isUsable)
    }

    func testLoopEngineClassifiesTurns() {
        let known: Set<String> = ["file_read", "calculator"]

        let toolDecision = AntigravityLoopEngine.decide(
            turnText: "TOOL_CALL {\"tool\": \"file_read\", \"arguments\": {\"path\": \"a.txt\"}}",
            knownToolIDs: known
        )
        guard case .callTool(let toolID, let args) = toolDecision else {
            return XCTFail("Expected a tool decision, got \(toolDecision)")
        }
        XCTAssertEqual(toolID, "file_read")
        XCTAssertEqual(args["path"], .string("a.txt"))

        let answerDecision = AntigravityLoopEngine.decide(
            turnText: "file_read: Read File — the contents are ready.",
            knownToolIDs: known
        )
        guard case .finalAnswer(let answer) = answerDecision else {
            return XCTFail("Expected a final answer, got \(answerDecision)")
        }
        XCTAssertFalse(answer.contains("file_read"))
    }

    /// The line the harness injects into every Agent system prompt: the
    /// model must be told the loop is genuinely there (or genuinely not).
    func testAgentModeContextLineReflectsStatus() {
        writeFile("google/antigravity/agent.py", contents: "# agent loop\n")
        writeManifest(files: [("google/antigravity/agent.py", "# agent loop\n")])
        let usable = AntigravitySDKBundle.status(directory: tempDir)
        let line = AntigravitySDKBundle.agentModeContextLine(status: usable)
        XCTAssertTrue(line.contains("0.1.20"), line)
        XCTAssertTrue(line.contains("integrity-verified"), line)
        // The line must not imply the SDK provides models/tools/prompts:
        // it provides the agent-loop design only, and models, tools, and
        // system prompts are Locally's own, from the context index.
        XCTAssertTrue(line.contains("agent-loop design only"), line)
        XCTAssertTrue(line.contains("Locally's own"), line)
        XCTAssertTrue(line.contains("context index"), line)

        let missing = AntigravitySDKBundle.agentModeContextLine(status: .init(isBundled: false))
        XCTAssertTrue(missing.contains("MISSING"), missing)
    }

    func testLoopEngineObservationPromptHidesToolID() {
        let prompt = AntigravityLoopEngine.observationPrompt(toolID: "file_read", output: "contents")
        XCTAssertFalse(prompt.contains("file_read"))
        XCTAssertTrue(prompt.contains("contents"))
    }
}
