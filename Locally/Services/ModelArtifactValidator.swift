import Foundation

/// Single source of truth for **where downloaded models actually live** — the
/// layout the app's inference engine (MLX Swift LM 2.30.6 on swift-transformers
/// 1.1.9 `HubApi`) reads. Verified against those pinned library sources:
///
/// - `MLXLMCommon.defaultHubApi` is `HubApi(downloadBase: ~/Library/Caches)`,
///   and `HubApi.localRepoLocation` appends `models/<org>/<name>`, so a model
///   is a directory of **real files** at `~/Library/Caches/models/<org>/<name>/`
///   (`config.json`, `model.safetensors`, `tokenizer.json`, … side by side).
/// - Every file carries a sibling metadata record at
///   `<model dir>/.cache/huggingface/download/<relative path>.metadata`
///   (three lines: commit hash, etag, unix timestamp).
/// - `HubApi.snapshot` in offline mode refuses to load unless the repo
///   directory exists, every (non-hidden) file in it has readable metadata,
///   and every LFS file's SHA-256 matches the etag in its metadata.
///
/// Anything else — including the Python-style `~/.cache/huggingface/hub`
/// `models--…/blobs + snapshots` layout — is invisible to the engine. Models
/// placed there can never be loaded, online or offline.
enum HFHubCache {
    /// `~/Library/Caches` — the `downloadBase` of MLX's `defaultHubApi`.
    nonisolated static var cachesDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches")
    }

    /// `~/Library/Caches/models` — one `<org>/<name>` directory per model.
    nonisolated static var modelsDirectory: URL {
        cachesDirectory.appendingPathComponent("models")
    }

    /// The directory MLX loads this model from.
    nonisolated static func modelDirectory(for modelID: String) -> URL {
        modelsDirectory.appending(path: modelID)
    }

    /// `<model dir>/.cache/huggingface/download` — HubApi's metadata folder.
    nonisolated static func metadataDirectory(for modelID: String) -> URL {
        modelDirectory(for: modelID)
            .appendingPathComponent(".cache/huggingface/download")
    }

    nonisolated static func metadataURL(for modelID: String, relativePath: String) -> URL {
        metadataDirectory(for: modelID)
            .appendingPathComponent(relativePath + ".metadata")
    }

    /// Every cached model id (`<org>/<name>`), complete or not — completeness
    /// is `ModelArtifactValidator`'s job, not the enumeration's.
    nonisolated static func cachedModelIDs() -> [String] {
        let fm = FileManager.default
        guard let orgs = try? fm.contentsOfDirectory(
            at: modelsDirectory, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        var ids: [String] = []
        for orgDir in orgs where !orgDir.lastPathComponent.hasPrefix(".") {
            guard (try? orgDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let models = try? fm.contentsOfDirectory(
                      at: orgDir, includingPropertiesForKeys: [.isDirectoryKey]
                  ) else { continue }
            for modelDir in models where !modelDir.lastPathComponent.hasPrefix(".") {
                guard (try? modelDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                else { continue }
                ids.append("\(orgDir.lastPathComponent)/\(modelDir.lastPathComponent)")
            }
        }
        return ids.sorted()
    }

    /// All real model files inside a model directory (recursive), excluding
    /// hidden files and the `.cache` metadata subtree — the same set
    /// `HubApi.snapshot` validates when offline.
    nonisolated static func modelFiles(in modelDir: URL) -> [(relativePath: String, url: URL)] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: modelDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let base = modelDir.path.hasSuffix("/") ? modelDir.path : modelDir.path + "/"
        var files: [(String, URL)] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            files.append((String(url.path.dropFirst(base.count)), url))
        }
        return files.sorted { $0.0 < $1.0 }
    }
}

/// Reads and writes the per-file `.metadata` records `HubApi` requires before
/// it will use a cached file — above all in offline mode, where a missing or
/// mismatched record makes the whole model unloadable. Format (identical to
/// what `HubApi.writeDownloadMetadata` itself writes):
/// line 1 = commit hash, line 2 = etag (SHA-256 for LFS files, git blob
/// SHA-1 otherwise), line 3 = unix timestamp.
enum HubDownloadMetadata {
    nonisolated static func content(commitHash: String, etag: String, timestamp: Date = .now) -> String {
        "\(commitHash)\n\(etag)\n\(timestamp.timeIntervalSince1970)\n"
    }

    nonisolated static func write(modelID: String, relativePath: String, commitHash: String, etag: String) throws {
        let url = HFHubCache.metadataURL(for: modelID, relativePath: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content(commitHash: commitHash, etag: etag)
            .write(to: url, atomically: true, encoding: .utf8)
    }

    /// Parses a metadata record the same way `HubApi.readDownloadMetadata`
    /// does: at least three lines and a numeric timestamp, or it's invalid.
    nonisolated static func read(modelID: String, relativePath: String) -> (commitHash: String, etag: String)? {
        let url = HFHubCache.metadataURL(for: modelID, relativePath: relativePath)
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = contents.components(separatedBy: .newlines)
        guard lines.count >= 3,
              Double(lines[2].trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        else { return nil }
        return (
            lines[0].trimmingCharacters(in: .whitespacesAndNewlines),
            lines[1].trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

/// One file of a Hugging Face repository, as reported by the repo tree API
/// (`GET /api/models/{id}/tree/main?recursive=true`). The models API itself only
/// returns file names in `siblings` — sizes and etags exist only here.
nonisolated struct HFRepoFile: Codable, Sendable, Hashable {
    /// Path inside the repository, e.g. `model-00001-of-00002.safetensors`.
    let path: String
    /// Exact byte size reported by Hugging Face.
    let size: Int64
    /// Blob etag: the LFS SHA-256 for large files, otherwise the git blob SHA-1.
    let etag: String
    /// SHA-256 for LFS files, `nil` for small git-stored files.
    let sha256: String?

    var isWeightFile: Bool { path.hasSuffix(".safetensors") }
}

/// The full file manifest for one model revision, persisted by the app
/// (Application Support `…/Locally/manifests/<org>--<name>.json`) so
/// completeness can be re-validated offline, byte for byte. It deliberately
/// lives **outside** the model directory: `HubApi`'s offline validation
/// rejects any file in that directory that has no `.metadata` record.
nonisolated struct HFModelManifest: Codable, Sendable {
    let modelID: String
    /// Commit SHA of the downloaded revision.
    let revision: String
    let files: [HFRepoFile]
    let fetchedAt: Date

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    nonisolated static func storageURL(for modelID: String) -> URL {
        JSONFileStore.directory
            .appendingPathComponent("manifests")
            .appendingPathComponent(modelID.replacingOccurrences(of: "/", with: "--") + ".json")
    }

    nonisolated static func load(for modelID: String) -> HFModelManifest? {
        guard let data = try? Data(contentsOf: storageURL(for: modelID)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(HFModelManifest.self, from: data)
    }

    nonisolated func save() throws {
        let url = Self.storageURL(for: modelID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Result of checking whether a model on disk is actually complete and loadable.
nonisolated struct ModelValidationResult: Sendable {
    let modelID: String
    /// True only when every required file is present with the expected size
    /// and the Hub metadata the engine's offline mode demands.
    let isComplete: Bool
    /// Human-readable problems, e.g. "Missing tokenizer.json". Empty when complete.
    let issues: [String]
    /// The model directory that passed (or was inspected), if it exists.
    let snapshotURL: URL?
    /// Total size of the model's files.
    let totalBytes: Int64
}

/// Validates downloaded models structurally — this, not "a folder exists", is
/// the definition of *installed* everywhere in the app. It mirrors exactly
/// what the inference engine will accept, online or fully offline:
///
/// 1. The model directory exists in the engine's cache (`~/Library/Caches/models/…`)
///    and contains files.
/// 2. `config.json` is present and non-empty.
/// 3. A tokenizer carrier is present (`tokenizer.json`, `tokenizer.model`, or
///    `vocab.json` + `merges.txt`).
/// 4. Weights: if `model.safetensors.index.json` exists, **every** shard named
///    in its `weight_map` must be present and non-empty; otherwise at least one
///    `.safetensors` file must be present and non-empty.
/// 5. Every file carries a readable Hub `.metadata` record — the engine's
///    offline mode throws without one — and, when an app manifest exists, each
///    file's size and metadata etag match the manifest exactly.
enum ModelArtifactValidator {

    nonisolated static func validate(modelID: String) -> ModelValidationResult {
        let fm = FileManager.default
        let modelDir = HFHubCache.modelDirectory(for: modelID)
        var issues: [String] = []

        guard fm.fileExists(atPath: modelDir.path) else {
            return ModelValidationResult(
                modelID: modelID,
                isComplete: false,
                issues: ["No downloaded model found"],
                snapshotURL: nil,
                totalBytes: 0
            )
        }

        let files = HFHubCache.modelFiles(in: modelDir)
        if files.isEmpty {
            issues.append("Model directory is empty")
        }
        let byRelativePath = Dictionary(uniqueKeysWithValues: files.map { ($0.relativePath, $0.url) })

        func fileSize(_ relativePath: String) -> Int64? {
            guard let url = byRelativePath[relativePath],
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            else { return nil }
            return Int64(size)
        }

        // 2. Config
        if let size = fileSize("config.json") {
            if size == 0 { issues.append("config.json is empty") }
        } else {
            issues.append("Missing config.json")
        }

        // 3. Tokenizer
        let hasTokenizerJSON = fileSize("tokenizer.json") != nil
        let hasTokenizerModel = fileSize("tokenizer.model") != nil
        let hasVocabPair = fileSize("vocab.json") != nil && fileSize("merges.txt") != nil
        if !hasTokenizerJSON && !hasTokenizerModel && !hasVocabPair {
            issues.append("Missing tokenizer files (tokenizer.json / tokenizer.model / vocab.json + merges.txt)")
        }

        // 4. Weights, shard-aware
        if let indexURL = byRelativePath["model.safetensors.index.json"] {
            if let data = try? Data(contentsOf: indexURL),
               let index = try? JSONDecoder().decode(SafetensorsIndex.self, from: data) {
                let shards = Set(index.weightMap.values)
                if shards.isEmpty {
                    issues.append("model.safetensors.index.json lists no weight shards")
                }
                for shard in shards.sorted() {
                    if let size = fileSize(shard) {
                        if size == 0 { issues.append("Weight shard \(shard) is empty") }
                    } else {
                        issues.append("Missing weight shard \(shard)")
                    }
                }
            } else {
                issues.append("model.safetensors.index.json could not be read")
            }
        } else {
            let weights = files.filter { $0.relativePath.hasSuffix(".safetensors") }
            if weights.isEmpty {
                issues.append("No .safetensors weight files found")
            } else if weights.allSatisfy({ (fileSize($0.relativePath) ?? 0) == 0 }) {
                issues.append("All .safetensors weight files are empty")
            }
        }

        // 5a. Hub metadata: the engine's offline mode requires a readable
        // .metadata record for every file, or it refuses to load the model.
        let manifest = HFModelManifest.load(for: modelID)
        let manifestByPath = manifest.map {
            Dictionary(uniqueKeysWithValues: $0.files.map { ($0.path, $0) })
        }
        for file in files {
            guard let metadata = HubDownloadMetadata.read(modelID: modelID, relativePath: file.relativePath) else {
                issues.append("Missing download metadata for \(file.relativePath) (required for offline use)")
                continue
            }
            if let expected = manifestByPath?[file.relativePath], metadata.etag != expected.etag {
                issues.append("\(file.relativePath) does not match the downloaded revision")
            }
        }

        // 5b. Manifest cross-check: every manifest file present at exact size.
        // Checked directly on disk (not via the enumerated set) because the
        // manifest can include hidden files like `.gitattributes`, which the
        // enumeration deliberately skips.
        if let manifest {
            for file in manifest.files {
                let url = modelDir.appending(path: file.path)
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    if Int64(size) != file.size {
                        issues.append("\(file.path) has wrong size (\(size) of \(file.size) bytes)")
                    }
                } else {
                    issues.append("Missing file \(file.path)")
                }
            }
        }

        let total = files.reduce(Int64(0)) { sum, file in
            sum + ((try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0)
        }
        return ModelValidationResult(
            modelID: modelID,
            isComplete: issues.isEmpty,
            issues: issues,
            snapshotURL: modelDir,
            totalBytes: total
        )
    }

    nonisolated static func isInstalled(modelID: String) -> Bool {
        validate(modelID: modelID).isComplete
    }

    nonisolated private struct SafetensorsIndex: Decodable, Sendable {
        let weightMap: [String: String]
        enum CodingKeys: String, CodingKey { case weightMap = "weight_map" }
    }
}
