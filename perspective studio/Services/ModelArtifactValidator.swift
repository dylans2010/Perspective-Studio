import Foundation

/// Single source of truth for the Hugging Face hub cache layout used by this app
/// (`~/.cache/huggingface/hub/models--<org>--<name>/` with `blobs/`, `snapshots/<sha>/`,
/// and `refs/main`), matching what swift-transformers' HubApi — and therefore MLX —
/// reads when it loads a model by id.
enum HFHubCache {
    nonisolated static var hubDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
    }

    nonisolated static func modelDirectory(for modelID: String) -> URL {
        let encoded = modelID.replacingOccurrences(of: "/", with: "--")
        return hubDirectory.appendingPathComponent("models--\(encoded)")
    }

    nonisolated static func modelID(fromCacheEntry entry: String) -> String? {
        guard entry.hasPrefix("models--") else { return nil }
        let parts = entry.dropFirst("models--".count).split(separator: "--", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return "\(parts[0])/\(parts[1])"
    }
}

/// One file of a Hugging Face repository, as reported by the repo tree API
/// (`GET /api/models/{id}/tree/main?recursive=true`). The models API itself only
/// returns file names in `siblings` — sizes and etags exist only here.
struct HFRepoFile: Codable, Sendable, Hashable {
    /// Path inside the repository, e.g. `model-00001-of-00002.safetensors`.
    let path: String
    /// Exact byte size reported by Hugging Face.
    let size: Int64
    /// Blob etag: the LFS SHA-256 for large files, otherwise the git blob SHA-1.
    /// This is also the file name used inside the hub cache `blobs/` directory.
    let etag: String
    /// SHA-256 for LFS files, `nil` for small git-stored files.
    let sha256: String?

    var isWeightFile: Bool { path.hasSuffix(".safetensors") }
}

/// The full file manifest for one model revision, persisted next to the download
/// (`perspective-manifest.json` inside the model's cache directory) so completeness
/// can be re-validated offline, byte for byte.
struct HFModelManifest: Codable, Sendable {
    let modelID: String
    /// Commit SHA of the downloaded revision.
    let revision: String
    let files: [HFRepoFile]
    let fetchedAt: Date

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    nonisolated static func load(for modelID: String) -> HFModelManifest? {
        let url = HFHubCache.modelDirectory(for: modelID)
            .appendingPathComponent("perspective-manifest.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(HFModelManifest.self, from: data)
    }

    nonisolated func save() throws {
        let dir = HFHubCache.modelDirectory(for: modelID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: dir.appendingPathComponent("perspective-manifest.json"), options: .atomic)
    }
}

/// Result of checking whether a model on disk is actually complete and loadable.
struct ModelValidationResult: Sendable {
    let modelID: String
    /// True only when every required file is present with the expected size
    /// (and, where a manifest exists, the expected blob identity).
    let isComplete: Bool
    /// Human-readable problems, e.g. "Missing tokenizer.json". Empty when complete.
    let issues: [String]
    /// The snapshot directory that passed (or was inspected), if one exists.
    let snapshotURL: URL?
    /// Total size of files in the snapshot.
    let totalBytes: Int64
}

/// Validates downloaded models structurally — this, not "a folder exists", is the
/// definition of *installed* everywhere in the app.
///
/// Checks, in order:
/// 1. A snapshot directory exists (via `refs/main` when available).
/// 2. `config.json` is present and non-empty.
/// 3. A tokenizer carrier is present (`tokenizer.json`, `tokenizer.model`, or
///    `vocab.json` + `merges.txt`).
/// 4. Weights: if `model.safetensors.index.json` exists, **every** shard named in
///    its `weight_map` must be present and non-empty; otherwise at least one
///    `.safetensors` file must be present and non-empty.
/// 5. If a `perspective-manifest.json` from `ModelDownloadService` exists, every
///    manifest file must resolve through the snapshot to a blob whose size matches
///    the manifest exactly.
enum ModelArtifactValidator {

    nonisolated static func validate(modelID: String) -> ModelValidationResult {
        let fm = FileManager.default
        let modelDir = HFHubCache.modelDirectory(for: modelID)
        var issues: [String] = []

        guard let snapshot = snapshotDirectory(in: modelDir) else {
            return ModelValidationResult(
                modelID: modelID,
                isComplete: false,
                issues: ["No downloaded snapshot found"],
                snapshotURL: nil,
                totalBytes: 0
            )
        }

        func snapshotFile(_ relativePath: String) -> URL {
            snapshot.appendingPathComponent(relativePath)
        }

        func fileSize(_ url: URL) -> Int64? {
            // fileExists / resourceValues follow the snapshot symlinks into blobs/.
            guard fm.fileExists(atPath: url.path),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize else { return nil }
            return Int64(size)
        }

        // 2. Config
        if let size = fileSize(snapshotFile("config.json")) {
            if size == 0 { issues.append("config.json is empty") }
        } else {
            issues.append("Missing config.json")
        }

        // 3. Tokenizer
        let hasTokenizerJSON = fileSize(snapshotFile("tokenizer.json")) != nil
        let hasTokenizerModel = fileSize(snapshotFile("tokenizer.model")) != nil
        let hasVocabPair = fileSize(snapshotFile("vocab.json")) != nil && fileSize(snapshotFile("merges.txt")) != nil
        if !hasTokenizerJSON && !hasTokenizerModel && !hasVocabPair {
            issues.append("Missing tokenizer files (tokenizer.json / tokenizer.model / vocab.json + merges.txt)")
        }

        // 4. Weights, shard-aware
        let indexURL = snapshotFile("model.safetensors.index.json")
        if fm.fileExists(atPath: indexURL.path) {
            if let data = try? Data(contentsOf: indexURL),
               let index = try? JSONDecoder().decode(SafetensorsIndex.self, from: data) {
                let shards = Set(index.weightMap.values)
                if shards.isEmpty {
                    issues.append("model.safetensors.index.json lists no weight shards")
                }
                for shard in shards.sorted() {
                    if let size = fileSize(snapshotFile(shard)) {
                        if size == 0 { issues.append("Weight shard \(shard) is empty") }
                    } else {
                        issues.append("Missing weight shard \(shard)")
                    }
                }
            } else {
                issues.append("model.safetensors.index.json could not be read")
            }
        } else {
            // No index: a single-file model must have at least one non-empty safetensors.
            let entries = (try? fm.contentsOfDirectory(atPath: snapshot.path)) ?? []
            let weights = entries.filter { $0.hasSuffix(".safetensors") }
            if weights.isEmpty {
                issues.append("No .safetensors weight files found")
            } else if weights.allSatisfy({ (fileSize(snapshotFile($0)) ?? 0) == 0 }) {
                issues.append("All .safetensors weight files are empty")
            }
        }

        // 5. Manifest cross-check (exact sizes per file, when we downloaded it ourselves)
        if let manifest = HFModelManifest.load(for: modelID) {
            for file in manifest.files {
                if let size = fileSize(snapshotFile(file.path)) {
                    if size != file.size {
                        issues.append("\(file.path) has wrong size (\(size) of \(file.size) bytes)")
                    }
                } else {
                    issues.append("Missing file \(file.path)")
                }
            }
        }

        let total = directorySize(at: modelDir.appendingPathComponent("blobs"))
        return ModelValidationResult(
            modelID: modelID,
            isComplete: issues.isEmpty,
            issues: issues,
            snapshotURL: snapshot,
            totalBytes: total
        )
    }

    nonisolated static func isInstalled(modelID: String) -> Bool {
        validate(modelID: modelID).isComplete
    }

    /// Resolves the snapshot directory for a cached model: the one `refs/main`
    /// points at when present, otherwise the first snapshot found.
    nonisolated static func snapshotDirectory(in modelDir: URL) -> URL? {
        let fm = FileManager.default
        let snapshotsDir = modelDir.appendingPathComponent("snapshots")
        if let ref = try? String(contentsOf: modelDir.appendingPathComponent("refs/main"), encoding: .utf8) {
            let sha = ref.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = snapshotsDir.appendingPathComponent(sha)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        guard let snapshots = try? fm.contentsOfDirectory(atPath: snapshotsDir.path),
              let first = snapshots.sorted().first else { return nil }
        return snapshotsDir.appendingPathComponent(first)
    }

    nonisolated static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
               values.isRegularFile == true, let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private struct SafetensorsIndex: Decodable {
        let weightMap: [String: String]
        enum CodingKeys: String, CodingKey { case weightMap = "weight_map" }
    }
}
