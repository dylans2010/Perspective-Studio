import XCTest
@testable import Locally

/// Agent Projects: folder-scoped agent work with per-project memory.
/// These tests pin the memory ordering, the context block the agent
/// actually receives, and the store's CRUD round-trip.
final class AgentProjectsTests: XCTestCase {

    private func sampleProject() -> AgentProject {
        AgentProject(
            name: "Demo",
            rootPath: "/tmp/demo-project",
            notes: "A demo codebase.",
            instructions: "Always run the tests.",
            memory: [
                AgentProjectMemoryEntry(text: "Older fact", createdAt: Date(timeIntervalSince1970: 100), kind: .fact),
                AgentProjectMemoryEntry(text: "Newer decision", createdAt: Date(timeIntervalSince1970: 200), kind: .fact)
            ]
        )
    }

    func testMemoryIsNewestFirst() {
        let project = sampleProject()
        XCTAssertEqual(project.memoryNewestFirst.map(\.text), ["Newer decision", "Older fact"])
    }

    func testProjectCodableRoundTrip() throws {
        let project = sampleProject()
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(AgentProject.self, from: data)
        XCTAssertEqual(decoded, project)
    }

    @MainActor
    func testContextBlockCarriesFolderNotesInstructionsAndMemory() {
        let block = AgentProjectsStore.shared.contextBlock(for: sampleProject())
        XCTAssertTrue(block.contains("[Active Project — Demo]"))
        XCTAssertTrue(block.contains("/tmp/demo-project"))
        XCTAssertTrue(block.contains("A demo codebase."))
        XCTAssertTrue(block.contains("Always run the tests."))
        XCTAssertTrue(block.contains("Newer decision"))
        XCTAssertTrue(block.contains("Older fact"))
    }

    @MainActor
    func testContextBlockWithoutMemoryOmitsTheMemorySectionEntirely() {
        let block = AgentProjectsStore.shared.contextBlock(for: sampleProject(), includeMemory: false)
        // No entries, and no memory-rules lines either.
        XCTAssertFalse(block.contains("Newer decision"))
        XCTAssertFalse(block.contains("Older fact"))
        XCTAssertFalse(block.contains("Project memory"))
        // The non-memory project context is still there.
        XCTAssertTrue(block.contains("[Active Project — Demo]"))
        XCTAssertTrue(block.contains("Always run the tests."))
    }

    @MainActor
    func testContextBlockForEmptyMemoryInvitesRecording() {
        var project = sampleProject()
        project.memory = []
        let block = AgentProjectsStore.shared.contextBlock(for: project)
        XCTAssertTrue(block.contains("Project memory: empty so far"))
    }

    @MainActor
    func testStoreCRUDAndMemoryRoundTrip() {
        let store = AgentProjectsStore.shared
        // The store is the app's real one — restore the user's selection
        // when the test is done.
        let originalSelection = store.selectedProjectID
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-project-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let project = store.addProject(rootURL: folder)
        defer {
            store.removeProject(id: project.id)
            store.select(originalSelection)
        }

        XCTAssertEqual(store.selectedProjectID, project.id)
        XCTAssertEqual(store.activeProject?.id, project.id)

        // Re-adding the same folder selects it instead of duplicating.
        let again = store.addProject(rootURL: folder)
        XCTAssertEqual(again.id, project.id)
        XCTAssertEqual(store.projects.filter { $0.id == project.id }.count, 1)

        store.addMemoryEntry(projectID: project.id, text: "Uses SwiftData for chats.", kind: .fact)
        store.addMemoryEntry(projectID: project.id, text: "Task: demo — Outcome: done.", kind: .session)
        let stored = store.project(id: project.id)
        XCTAssertEqual(stored?.memory.count, 2)

        if let entry = stored?.memory.first {
            store.removeMemoryEntry(projectID: project.id, entryID: entry.id)
        }
        XCTAssertEqual(store.project(id: project.id)?.memory.count, 1)

        store.removeProject(id: project.id)
        XCTAssertNil(store.project(id: project.id))
        XCTAssertNil(store.selectedProjectID)
    }

    /// Projects saved before the pinned-files / commands / mandate fields
    /// existed must decode with defaults — never be silently dropped.
    func testLegacyProjectJSONDecodesWithDefaults() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","name":"Old","rootPath":"/tmp/old","notes":"","instructions":"","memory":[],"createdAt":0,"updatedAt":0}
        """
        // Dates encode as seconds since 2001 in the default strategy the
        // store round-trips with; decode with the matching default.
        let decoded = try JSONDecoder().decode(AgentProject.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.name, "Old")
        XCTAssertEqual(decoded.pinnedFilePaths, [])
        XCTAssertEqual(decoded.buildCommand, "")
        XCTAssertEqual(decoded.testCommand, "")
        XCTAssertTrue(decoded.requireToolUse)
    }

    func testNewFieldsRoundTrip() throws {
        var project = sampleProject()
        project.pinnedFilePaths = ["README.md", "docs/arch.md"]
        project.buildCommand = "swift build"
        project.testCommand = "swift test"
        project.requireToolUse = false
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(AgentProject.self, from: data)
        XCTAssertEqual(decoded, project)
    }

    @MainActor
    func testContextBlockCarriesMandateCommandsAndPinnedFiles() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-project-context-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "# Pinned Doc\nKey facts live here.".write(
            to: folder.appendingPathComponent("PINNED.md"), atomically: true, encoding: .utf8
        )
        try "Package.swift".write(
            to: folder.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8
        )

        var project = AgentProject(name: "Ctx", rootPath: folder.path)
        project.pinnedFilePaths = ["PINNED.md"]
        project.buildCommand = "swift build"
        project.testCommand = "swift test"

        let block = AgentProjectsStore.shared.contextBlock(for: project)
        XCTAssertTrue(block.contains("TOOL MANDATE"), block)
        XCTAssertTrue(block.contains("Build: swift build"), block)
        XCTAssertTrue(block.contains("Test: swift test"), block)
        XCTAssertTrue(block.contains("Key facts live here."), block)
        XCTAssertTrue(block.contains("Swift Package"), block)
    }

    func testSnapshotDetectsKindsAndGitBranch() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-project-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "// swift".write(to: folder.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let gitDir = folder.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "ref: refs/heads/feature/work\n".write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)

        let project = AgentProject(name: "Snap", rootPath: folder.path)
        XCTAssertEqual(AgentProjectSnapshot.detectKind(root: folder).label, "Swift Package")
        XCTAssertEqual(AgentProjectSnapshot.gitBranch(root: folder), "feature/work")
        XCTAssertTrue(AgentProjectSnapshot.summaryLine(for: project).contains("Swift Package"))
    }
}
