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
}
