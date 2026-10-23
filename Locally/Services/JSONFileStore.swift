import Foundation

/// Minimal versioned-JSON persistence for app-level libraries (prompts,
/// benchmarks, knowledge bases, profiles). Files live in
/// `Application Support/Locally/`; every payload is wrapped in an
/// envelope with a `schemaVersion` so future migrations have a hook, instead
/// of these stores being coupled to the SwiftData schema used for chats.
enum JSONFileStore {
    struct Envelope<Payload: Codable>: Codable {
        var schemaVersion: Int
        var payload: Payload
    }

    nonisolated static var directory: URL { migratedDirectory }

    /// The Application Support folder, computed once. If the legacy
    /// `PerspectiveStudio` folder (from before the app was renamed Locally)
    /// still exists and the new one doesn't, it is moved over so prompts,
    /// benchmarks, knowledge bases, manifests, and attachments survive.
    private nonisolated static let migratedDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let current = base.appendingPathComponent("Locally")
        let legacy = base.appendingPathComponent("PerspectiveStudio")
        let fm = FileManager.default
        if !fm.fileExists(atPath: current.path), fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: current)
        }
        return current
    }()

    nonisolated static func load<Payload: Codable>(_ type: Payload.Type, filename: String) -> Payload? {
        let url = directory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Envelope<Payload>.self, from: data).payload
    }

    nonisolated static func save<Payload: Codable>(_ payload: Payload, filename: String, schemaVersion: Int = 1) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Envelope(schemaVersion: schemaVersion, payload: payload))
            try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
        } catch {
            // Persistence failures must be visible, never silently swallowed.
            print("❌ [Locally] Failed to save \(filename): \(error.localizedDescription)")
        }
    }

    nonisolated static func loadDecodable<Payload: Decodable>(_ type: Payload.Type, filename: String) -> Payload? {
        load(type, filename: filename)
    }
}
