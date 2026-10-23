import Foundation
import CryptoKit

struct ModelDownloadProgress: Sendable {
    let modelID: String
    let fractionCompleted: Double
    let downloadedBytes: Int64
    let totalBytes: Int64
    let currentFile: String
}

enum ModelDownloadError: LocalizedError {
    case invalidModelID(String)
    case httpError(Int, file: String?)
    case manifestFailed(String)
    case sizeMismatch(file: String, expected: Int64, actual: Int64)
    case hashMismatch(file: String)
    case incompleteDownload([String])

    var errorDescription: String? {
        switch self {
        case .invalidModelID(let id): "Invalid model id: \(id)"
        case .httpError(let code, let file):
            if let file {
                "Hugging Face returned HTTP \(code) while downloading \(file)"
            } else {
                "Hugging Face returned HTTP \(code)"
            }
        case .manifestFailed(let detail): "Could not read the model's file list from Hugging Face: \(detail)"
        case .sizeMismatch(let file, let expected, let actual):
            "\(file) downloaded with the wrong size (\(actual) of \(expected) bytes)"
        case .hashMismatch(let file): "\(file) failed its SHA-256 integrity check"
        case .incompleteDownload(let issues):
            "Download did not complete: \(issues.joined(separator: "; "))"
        }
    }
}

/// The app's real Hugging Face downloader.
///
/// This replaces the old behaviour where "download" meant "ask MLX to load the
/// model", which never enumerated the repository, never verified anything, and
/// let partial downloads be reported as installed.
///
/// How it works:
/// 1. Fetch the repo manifest from `GET /api/models/{id}/tree/main?recursive=true`
///    (the models API's `siblings` list has no sizes or etags — verified live).
/// 2. Download **every** file into the standard hub cache layout
///    (`blobs/<etag>`, `snapshots/<revision>/…` symlinks, `refs/main`) that
///    MLX / swift-transformers reads, so a download is usable entirely offline.
/// 3. Large files and redirects are handled by `URLSession` download tasks;
///    interrupted downloads persist `NSURLSession` resume data next to the blob
///    and are resumed (not restarted) on the next attempt, with up to 3 attempts
///    per file.
/// 4. Every file is verified: exact byte size for all files, SHA-256 for LFS
///    files. A model is only reported downloaded when
///    `ModelArtifactValidator` confirms the whole artifact is complete —
///    including every shard named by `model.safetensors.index.json`, the
///    config, and the tokenizer files.
actor ModelDownloadService {
    static let shared = ModelDownloadService()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 7 * 24 * 3600
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    private var activeTasks: [String: URLSessionDownloadTask] = [:]
    private var cancelledModelIDs: Set<String> = []

    // MARK: - Manifest

    func fetchManifest(modelID: String) async throws -> HFModelManifest {
        guard modelID.contains("/"), !modelID.contains(" ") else {
            throw ModelDownloadError.invalidModelID(modelID)
        }
        let encodedID = modelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? modelID

        // Revision (commit SHA) from the models API.
        guard let infoURL = URL(string: "https://huggingface.co/api/models/\(encodedID)") else {
            throw ModelDownloadError.invalidModelID(modelID)
        }
        let (infoData, infoResponse) = try await session.data(from: infoURL)
        try requireSuccess(infoResponse, file: nil)
        let info = try JSONDecoder().decode(ModelInfoResponse.self, from: infoData)

        // File list with sizes + etags from the tree API.
        guard let treeURL = URL(string: "https://huggingface.co/api/models/\(encodedID)/tree/main?recursive=true") else {
            throw ModelDownloadError.invalidModelID(modelID)
        }
        let (treeData, treeResponse) = try await session.data(from: treeURL)
        try requireSuccess(treeResponse, file: nil)
        let entries: [RepoTreeEntry]
        do {
            entries = try JSONDecoder().decode([RepoTreeEntry].self, from: treeData)
        } catch {
            throw ModelDownloadError.manifestFailed(error.localizedDescription)
        }

        let files = entries.compactMap { entry -> HFRepoFile? in
            guard entry.type == "file", let size = entry.size, let oid = entry.oid else { return nil }
            if let lfs = entry.lfs {
                return HFRepoFile(path: entry.path, size: lfs.size, etag: lfs.oid, sha256: lfs.oid)
            }
            return HFRepoFile(path: entry.path, size: size, etag: oid, sha256: nil)
        }
        guard !files.isEmpty else {
            throw ModelDownloadError.manifestFailed("repository lists no downloadable files")
        }

        return HFModelManifest(modelID: modelID, revision: info.sha, files: files, fetchedAt: .now)
    }

    // MARK: - Download

    /// Downloads (or resumes) the complete model and validates it.
    /// Throws — and leaves the model *not installed* — if anything is missing.
    func download(
        modelID: String,
        progress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws -> ModelValidationResult {
        cancelledModelIDs.remove(modelID)
        let manifest = try await fetchManifest(modelID: modelID)
        try manifest.save()

        let fm = FileManager.default
        let modelDir = HFHubCache.modelDirectory(for: modelID)
        let blobsDir = modelDir.appendingPathComponent("blobs")
        let snapshotDir = modelDir.appendingPathComponent("snapshots")
            .appendingPathComponent(manifest.revision)
        try fm.createDirectory(at: blobsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: snapshotDir, withIntermediateDirectories: true)

        let totalBytes = max(manifest.totalBytes, 1)
        var completedBytes: Int64 = 0

        // Smallest first: config/tokenizer failures surface before gigabytes of weights.
        for file in manifest.files.sorted(by: { $0.size < $1.size }) {
            if cancelledModelIDs.contains(modelID) { throw CancellationError() }
            let blobURL = blobsDir.appendingPathComponent(file.etag)

            if await blobIsValid(blobURL, file: file) {
                completedBytes += file.size
            } else {
                try? fm.removeItem(at: blobURL)
                // Immutable snapshot of the finished-bytes total, so the
                // @Sendable progress closure captures only `let` values.
                let baseCompleted = completedBytes
                let filePath = file.path
                try await downloadFile(
                    file,
                    modelID: modelID,
                    destination: blobURL
                ) { inFlight in
                    let done = min(baseCompleted + inFlight, totalBytes)
                    progress(ModelDownloadProgress(
                        modelID: modelID,
                        fractionCompleted: Double(done) / Double(totalBytes),
                        downloadedBytes: done,
                        totalBytes: totalBytes,
                        currentFile: filePath
                    ))
                }
                completedBytes += file.size
            }

            try linkIntoSnapshot(file: file, snapshotDir: snapshotDir, modelDir: modelDir)
            progress(ModelDownloadProgress(
                modelID: modelID,
                fractionCompleted: Double(min(completedBytes, totalBytes)) / Double(totalBytes),
                downloadedBytes: min(completedBytes, totalBytes),
                totalBytes: totalBytes,
                currentFile: file.path
            ))
        }

        // Record the revision the way HubApi expects.
        let refsDir = modelDir.appendingPathComponent("refs")
        try fm.createDirectory(at: refsDir, withIntermediateDirectories: true)
        try manifest.revision.write(to: refsDir.appendingPathComponent("main"), atomically: true, encoding: .utf8)

        progress(ModelDownloadProgress(
            modelID: modelID, fractionCompleted: 1, downloadedBytes: totalBytes,
            totalBytes: totalBytes, currentFile: ""
        ))

        let validation = ModelArtifactValidator.validate(modelID: modelID)
        guard validation.isComplete else {
            throw ModelDownloadError.incompleteDownload(validation.issues)
        }
        return validation
    }

    func cancel(modelID: String) {
        cancelledModelIDs.insert(modelID)
        activeTasks[modelID]?.cancel()
    }

    func isDownloading(modelID: String) -> Bool {
        activeTasks[modelID] != nil
    }

    // MARK: - Per-file download with resume + retry

    private func downloadFile(
        _ file: HFRepoFile,
        modelID: String,
        destination: URL,
        inFlightProgress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let resumeDataURL = destination.appendingPathExtension("resume")
        var lastError: Error?

        for attempt in 0..<3 {
            if cancelledModelIDs.contains(modelID) { throw CancellationError() }
            do {
                let tempURL = try await performDownloadTask(
                    file: file,
                    modelID: modelID,
                    resumeDataURL: resumeDataURL,
                    inFlightProgress: inFlightProgress
                )
                // Verify before the blob becomes visible under its final name.
                let stagingURL = destination.appendingPathExtension("complete")
                let fm = FileManager.default
                try? fm.removeItem(at: stagingURL)
                try fm.moveItem(at: tempURL, to: stagingURL)

                let actualSize = (try? stagingURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
                guard actualSize == file.size else {
                    try? fm.removeItem(at: stagingURL)
                    throw ModelDownloadError.sizeMismatch(file: file.path, expected: file.size, actual: actualSize)
                }
                if let expectedHash = file.sha256 {
                    let actualHash = try await Task.detached(priority: .utility) {
                        try Self.sha256Hex(of: stagingURL)
                    }.value
                    guard actualHash == expectedHash else {
                        try? fm.removeItem(at: stagingURL)
                        throw ModelDownloadError.hashMismatch(file: file.path)
                    }
                }
                try? fm.removeItem(at: destination)
                try fm.moveItem(at: stagingURL, to: destination)
                try? fm.removeItem(at: resumeDataURL)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if cancelledModelIDs.contains(modelID) { throw CancellationError() }
                if attempt < 2 {
                    try? await Task.sleep(for: .seconds(Double(attempt + 1) * 2))
                }
            }
        }
        throw lastError ?? ModelDownloadError.manifestFailed("download of \(file.path) failed")
    }

    /// Runs one download task to completion. Follows redirects (URLSession does),
    /// streams large files to a temporary file on disk, polls the task's
    /// `Progress` for UI updates, and persists resume data whenever the task
    /// ends with an error that provides it.
    private func performDownloadTask(
        file: HFRepoFile,
        modelID: String,
        resumeDataURL: URL,
        inFlightProgress: @escaping @Sendable (Int64) -> Void
    ) async throws -> URL {
        // The downloaded temp file only lives for the duration of the completion
        // handler, so the handler moves it to our own staging location first.
        // Everything the @Sendable continuation closure needs is resolved here,
        // on the actor, before entering it.
        let stagingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("perspective-download-\(UUID().uuidString)")
        let session = self.session
        let resumeData = (try? Data(contentsOf: resumeDataURL)).flatMap { $0.isEmpty ? nil : $0 }
        let requestURL = resumeData == nil ? resolveURL(modelID: modelID, path: file.path) : nil
        guard resumeData != nil || requestURL != nil else {
            throw ModelDownloadError.invalidModelID(modelID)
        }

        let result: URL = try await withCheckedThrowingContinuation { continuation in
            let completion: @Sendable (URL?, URLResponse?, Error?) -> Void = { tempURL, response, error in
                if let error {
                    // Persist resume data so the next attempt continues this file
                    // instead of restarting a multi-GB shard from byte zero.
                    if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                        try? data.write(to: resumeDataURL)
                    }
                    if (error as NSError).code == NSURLErrorCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    continuation.resume(throwing: ModelDownloadError.httpError(http.statusCode, file: file.path))
                    return
                }
                guard let tempURL else {
                    continuation.resume(throwing: ModelDownloadError.manifestFailed("download produced no file"))
                    return
                }
                do {
                    try? FileManager.default.removeItem(at: stagingURL)
                    try FileManager.default.moveItem(at: tempURL, to: stagingURL)
                    continuation.resume(returning: stagingURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            let task: URLSessionDownloadTask
            if let resumeData {
                task = session.downloadTask(withResumeData: resumeData, completionHandler: completion)
            } else if let requestURL {
                var request = URLRequest(url: requestURL)
                request.timeoutInterval = 300
                task = session.downloadTask(with: request, completionHandler: completion)
            } else {
                continuation.resume(throwing: ModelDownloadError.invalidModelID(modelID))
                return
            }

            Task { await self.register(task: task, for: modelID) }
            Task {
                // Poll progress until the download task leaves the running state.
                while task.state == .running || task.state == .suspended {
                    inFlightProgress(task.progress.completedUnitCount)
                    try? await Task.sleep(for: .milliseconds(200))
                }
                inFlightProgress(task.progress.completedUnitCount)
            }
            task.resume()
        }

        await unregister(modelID: modelID)
        return result
    }

    private func register(task: URLSessionDownloadTask, for modelID: String) {
        activeTasks[modelID] = task
    }

    private func unregister(modelID: String) {
        activeTasks[modelID] = nil
    }

    // MARK: - Helpers

    private func resolveURL(modelID: String, path: String) -> URL? {
        let encodedPath = path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        let encodedID = modelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? modelID
        return URL(string: "https://huggingface.co/\(encodedID)/resolve/main/\(encodedPath)")
    }

    private func requireSuccess(_ response: URLResponse, file: String?) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ModelDownloadError.httpError(http.statusCode, file: file)
        }
    }

    /// A blob counts as already downloaded only at the exact expected size and,
    /// for LFS files, with a matching SHA-256 — never merely because it exists.
    /// Runs detached so hashing a multi-GB blob never blocks the service actor.
    private func blobIsValid(_ blobURL: URL, file: HFRepoFile) async -> Bool {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard fm.fileExists(atPath: blobURL.path),
                  let size = try? blobURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  Int64(size) == file.size else { return false }
            guard let expectedHash = file.sha256 else { return true }
            guard let actualHash = try? Self.sha256Hex(of: blobURL) else { return false }
            return actualHash == expectedHash
        }.value
    }

    private func linkIntoSnapshot(file: HFRepoFile, snapshotDir: URL, modelDir: URL) throws {
        let fm = FileManager.default
        let linkURL = snapshotDir.appendingPathComponent(file.path)
        try fm.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: linkURL)
        // Relative symlink: from the link's directory back up to the model dir, then into blobs/.
        let depthBelowModelDir = linkURL.deletingLastPathComponent().pathComponents.count - modelDir.pathComponents.count
        let ups = String(repeating: "../", count: max(depthBelowModelDir, 1))
        try fm.createSymbolicLink(atPath: linkURL.path, withDestinationPath: "\(ups)blobs/\(file.etag)")
    }

    nonisolated static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0" + hex : hex
        }.joined()
    }

    // MARK: - HF API DTOs

    private struct ModelInfoResponse: Decodable {
        let sha: String
    }

    private struct RepoTreeEntry: Decodable {
        let type: String
        let path: String
        let size: Int64?
        let oid: String?
        let lfs: LFSInfo?

        struct LFSInfo: Decodable {
            let oid: String
            let size: Int64
        }
    }
}
