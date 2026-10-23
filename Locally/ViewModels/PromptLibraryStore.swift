import Foundation

struct PromptTemplate: Codable, Identifiable, Sendable, Hashable {
    var id: UUID = UUID()
    var title: String
    var body: String
    var category: String
    var createdAt: Date = .now
    var updatedAt: Date = .now
}

/// Prompt library (feature F): create / edit / organize / search / import /
/// export reusable prompts, plus per-model generation profiles.
/// Persisted as versioned JSON via `JSONFileStore`.
@Observable @MainActor
final class PromptLibraryStore {
    static let shared = PromptLibraryStore()

    private(set) var prompts: [PromptTemplate] = []
    private(set) var profiles: [GenerationProfile] = []
    var searchQuery: String = ""

    private let promptsFile = "prompts.json"
    private let profilesFile = "generation-profiles.json"

    init() {
        if let loaded = JSONFileStore.load([PromptTemplate].self, filename: promptsFile) {
            prompts = loaded
        } else {
            prompts = Self.builtInPrompts
            persistPrompts()
        }
        profiles = JSONFileStore.load([GenerationProfile].self, filename: profilesFile) ?? []
    }

    var filteredPrompts: [PromptTemplate] {
        guard !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return prompts }
        return prompts.filter {
            $0.title.localizedStandardContains(searchQuery)
                || $0.body.localizedStandardContains(searchQuery)
                || $0.category.localizedStandardContains(searchQuery)
        }
    }

    var categories: [String] {
        Array(Set(prompts.map(\.category))).sorted()
    }

    // MARK: - Prompts CRUD

    func addPrompt(title: String, body: String, category: String) {
        prompts.append(PromptTemplate(title: title, body: body, category: category.isEmpty ? "General" : category))
        persistPrompts()
    }

    func updatePrompt(_ prompt: PromptTemplate) {
        guard let index = prompts.firstIndex(where: { $0.id == prompt.id }) else { return }
        var updated = prompt
        updated.updatedAt = .now
        prompts[index] = updated
        persistPrompts()
    }

    func deletePrompt(_ prompt: PromptTemplate) {
        prompts.removeAll { $0.id == prompt.id }
        persistPrompts()
    }

    // MARK: - Import / Export

    func exportPromptsJSON() -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(prompts), let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    /// Imports prompts from JSON produced by `exportPromptsJSON`.
    /// Returns the number imported; throws on malformed input so the UI can
    /// show the failure instead of pretending it worked.
    @discardableResult
    func importPromptsJSON(_ json: String) throws -> Int {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let incoming = try decoder.decode([PromptTemplate].self, from: Data(json.utf8))
        var imported = 0
        for var prompt in incoming {
            if prompts.contains(where: { $0.id == prompt.id }) {
                prompt.id = UUID()
            }
            prompts.append(prompt)
            imported += 1
        }
        persistPrompts()
        return imported
    }

    // MARK: - Profiles CRUD

    func profile(forModel modelID: String) -> GenerationProfile? {
        profiles.first { $0.modelID == modelID } ?? profiles.first { $0.modelID == nil }
    }

    func saveProfile(_ profile: GenerationProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        JSONFileStore.save(profiles, filename: profilesFile)
    }

    func deleteProfile(_ profile: GenerationProfile) {
        profiles.removeAll { $0.id == profile.id }
        JSONFileStore.save(profiles, filename: profilesFile)
    }

    // MARK: - Private

    private func persistPrompts() {
        JSONFileStore.save(prompts, filename: promptsFile)
    }

    private static var builtInPrompts: [PromptTemplate] {
        [
            PromptTemplate(title: "Explain Like I'm New", body: "Explain the following topic simply, with one concrete example, avoiding jargon: ", category: "General"),
            PromptTemplate(title: "Code Review", body: "Review the following code for bugs, edge cases, and simplifications. List findings by severity, then suggest fixes:\n\n", category: "Coding"),
            PromptTemplate(title: "Write a Function", body: "Write a clean, well-named function that does the following, with a short explanation of how it works:\n\n", category: "Coding"),
            PromptTemplate(title: "Summarize Research", body: "Summarize the following text into key claims, evidence, and open questions:\n\n", category: "Research"),
            PromptTemplate(title: "Compare Options", body: "Compare the following options in a table, then recommend one and say why:\n\n", category: "Research"),
            PromptTemplate(title: "Rewrite Clearly", body: "Rewrite the following text to be clearer and more concise while keeping its meaning:\n\n", category: "Writing"),
        ]
    }
}
