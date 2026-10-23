import Foundation
import CryptoKit

/// The bundled Antigravity SDK, shipped inside Locally.
///
/// The genuine upstream SDK (`google-antigravity`, Apache-2.0) is vendored
/// under `Locally/AntigravitySDK/` and copied into the app bundle, so Agent
/// mode never depends on anything the user must install. Its role is
/// strictly bounded by policy:
///
/// - **Loops only.** The SDK provides the agent-loop layer. Locally's loop
///   engine (`AntigravityLoopEngine`) implements that contract natively,
///   and the vendored SDK ships for interoperability and inspection.
/// - **No models.** The SDK's compiled model/tool runtime
///   (`bin/localharness`) is NOT bundled — it is excluded at vendor time,
///   and `status()` fails verification if any executable runtime or native
///   binary appears in the bundle. Inference is always the user's local
///   models via `InferenceBackend`.
/// - **No tools.** The SDK's built-in tools are never registered or run.
///   Every tool the agent can call is Locally's own, from `ToolsRegistry`.
///
/// Integrity is verified against `sdk-manifest.json` (SHA-256 per file),
/// generated when the SDK was vendored — a tampered or partial bundle is
/// reported, never silently trusted.
public enum AntigravitySDKBundle {

    public struct Status: Sendable, Equatable {
        public var isBundled: Bool = false
        public var version: String? = nil
        public var fileCount: Int = 0
        public var totalBytes: Int = 0
        public var integrityVerified: Bool = false
        /// True when an executable model/tool runtime or native binary is
        /// present — a violation of the loop-only policy.
        public var containsExecutableRuntime: Bool = false
        public var issues: [String] = []

        /// The bundled SDK can serve as the loop layer: present, intact,
        /// and free of any model/tool runtime.
        public var isUsable: Bool {
            isBundled && integrityVerified && !containsExecutableRuntime
        }

        public var summary: String {
            guard isBundled else { return "Antigravity SDK is not bundled in this build." }
            let size = ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
            let versionText = version.map { " \($0)" } ?? ""
            if isUsable {
                return "Antigravity SDK\(versionText) bundled — loop-only, integrity verified (\(fileCount) files, \(size))."
            }
            return "Antigravity SDK\(versionText) bundled (\(fileCount) files, \(size)) — verification issues found."
        }
    }

    private nonisolated struct Manifest: Decodable, Sendable {
        var sdk: String
        var version: String
        var files: [ManifestFile]
    }

    private nonisolated struct ManifestFile: Decodable, Sendable {
        var path: String
        var sha256: String
        var bytes: Int
    }

    // MARK: - Location

    /// Finds the bundled SDK directory: the app bundle's resources first,
    /// then the source-tree locations a dev build runs from.
    ///
    /// The SDK reaches the bundle through an explicit *folder reference*
    /// in the Xcode project (`AntigravitySDK` in the Locally target's
    /// Resources phase), so a built app contains a real
    /// `Contents/Resources/AntigravitySDK/` directory with the vendored
    /// tree intact — directory structure preserved, which the per-file
    /// synchronized-group copy could never provide (it flattens resources
    /// and collides on the SDK's many `__init__.py` files; those files are
    /// membership-excepted from the synchronized group for exactly that
    /// reason, and this folder reference is what actually ships them).
    public nonisolated static func bundledDirectory(bundle: Bundle = .main) -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let resourceURL = bundle.resourceURL {
            candidates.append(resourceURL.appending(path: "AntigravitySDK"))
        }
        if let url = bundle.url(forResource: "AntigravitySDK", withExtension: nil) {
            candidates.append(url)
        }
        // Folder-reference copies are also addressable by subdirectory —
        // resolve through the manifest itself so a layout change in the
        // bundle can never silently orphan the SDK.
        if let manifestURL = bundle.url(forResource: "sdk-manifest", withExtension: "json", subdirectory: "AntigravitySDK") {
            candidates.append(manifestURL.deletingLastPathComponent())
        }
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        candidates.append(cwd.appending(path: "Locally/AntigravitySDK"))
        candidates.append(cwd.appending(path: "AntigravitySDK"))

        for candidate in candidates {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: candidate.appending(path: "sdk-manifest.json").path),
               fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }

    /// One prompt-ready line describing the SDK's state for an Agent-mode
    /// run. The harness injects this into every Agent system prompt so the
    /// model knows the loop it is running inside of is present and usable —
    /// or, if verification failed, that it must say so instead of assuming.
    public nonisolated static func agentModeContextLine(status: Status) -> String {
        if status.isUsable {
            return "Agent engine: the bundled Antigravity SDK \(status.version ?? "") is present and integrity-verified (\(status.fileCount) files). Its agent loop is running this conversation — every tool call you make goes through it."
        }
        if status.isBundled {
            return "Agent engine: the bundled Antigravity SDK is present but failed verification (\(status.issues.joined(separator: " "))). The native loop still runs this conversation; if the user asks about the agent engine, tell them it reported a problem instead of claiming it is healthy."
        }
        return "Agent engine: the Antigravity SDK bundle is MISSING from this build. The native loop still runs this conversation; if the user asks about the agent engine, tell them the SDK is not bundled in this build instead of claiming it is."
    }

    // MARK: - Status & verification

    public nonisolated static func status(bundle: Bundle = .main) -> Status {
        guard let directory = bundledDirectory(bundle: bundle) else {
            return Status(isBundled: false, issues: ["The Antigravity SDK was not found in the app bundle. Agent mode's native loop still runs, but the bundled SDK is missing."])
        }
        return status(directory: directory)
    }

    /// Verifies one SDK directory against its manifest. Exposed for tests
    /// and for the Settings status row.
    public nonisolated static func status(directory: URL) -> Status {
        var status = Status(isBundled: true)
        let fm = FileManager.default
        let manifestURL = directory.appending(path: "sdk-manifest.json")

        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData) else {
            status.issues.append("The SDK manifest is missing or unreadable, so the bundle cannot be verified.")
            return status
        }

        status.version = manifest.version
        status.fileCount = manifest.files.count

        var allIntact = true
        for file in manifest.files {
            let fileURL = directory.appending(path: file.path)
            guard let data = try? Data(contentsOf: fileURL) else {
                status.issues.append("Missing SDK file: \(file.path)")
                allIntact = false
                continue
            }
            status.totalBytes += data.count
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if data.count != file.bytes || digest != file.sha256 {
                status.issues.append("SDK file failed integrity check: \(file.path)")
                allIntact = false
            }
        }
        status.integrityVerified = allIntact && !manifest.files.isEmpty

        // Loop-only policy scan: the shipped tree must be inert source —
        // no compiled harness, no native libraries, nothing executable
        // that could run the SDK's own models or tools.
        let forbiddenExtensions: Set<String> = ["so", "dylib", "gz", "whl", "zip", "o", "a"]
        if let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let fileURL as URL in enumerator {
                let name = fileURL.lastPathComponent.lowercased()
                // The compiled harness binary itself (any platform build),
                // never its inert *_pb2.py message definitions.
                let isHarnessBinary = name == "localharness" || name.hasPrefix("localharness.")
                if isHarnessBinary || forbiddenExtensions.contains(fileURL.pathExtension.lowercased()) {
                    status.containsExecutableRuntime = true
                    status.issues.append("Executable runtime found in the SDK bundle (\(fileURL.lastPathComponent)) — the SDK is loop-only and must not ship one.")
                    break
                }
            }
        }

        return status
    }
}
