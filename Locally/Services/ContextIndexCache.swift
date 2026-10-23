import CryptoKit
import Foundation

/// In-memory cache for the live context index, so consulting the index
/// is cheap enough to do on every request, for every model.
///
/// Building the index is the expensive part — rendering every tool's
/// schema text, fetching every system asset's content, tokenizing every
/// payload — and a single request used to trigger that build two to
/// four times (directory + retrieved bundle, then again inside the
/// agent harness). This cache keys the built entries on a *fingerprint*
/// of everything the index is built from, computed from cheap signals
/// only:
///
/// - tools: the sorted registered tool ids (tools are compiled into the
///   app; their ids identify them for a given build),
/// - system assets: each asset's id, filename, summary, and — when the
///   asset lives in a file — that file's modification date. Asset file
///   *contents* are never read for the fingerprint (the assets manager
///   has its own content cache; a changed file changes its stamp),
/// - skills: each skill's id plus a SHA-256 of its markdown (hashing a
///   string is far cheaper than rendering/tokenizing around it),
/// - the global + conversation custom-prompt strings, hashed,
/// - the active-skill id set, hashed,
/// - the active project (Agent mode only): its id, memory count, and a
///   hash of its memory texts.
///
/// When the fingerprint matches, `entries(fingerprint:build:)` returns
/// the cached entries and the build closure never runs. Any real change
/// — a skill edited, a memory entry recorded, a prompt changed, an
/// asset file touched — changes the fingerprint and rebuilds once.
@MainActor
public final class ContextIndexCache {
    public static let shared = ContextIndexCache()

    /// The cheap input fingerprint the cached entries were built from.
    public struct Fingerprint: Equatable, Sendable {
        public var mode: ContextIndexManager.Mode
        public var tools: String
        public var assets: String
        public var skills: String
        public var activeSkills: String
        public var prompts: String
        public var project: String

        public init(
            mode: ContextIndexManager.Mode,
            tools: String,
            assets: String,
            skills: String,
            activeSkills: String,
            prompts: String,
            project: String
        ) {
            self.mode = mode
            self.tools = tools
            self.assets = assets
            self.skills = skills
            self.activeSkills = activeSkills
            self.prompts = prompts
            self.project = project
        }
    }

    private var storedFingerprint: Fingerprint?
    private var storedEntries: [ContextIndexManager.Entry] = []

    /// How many times the index has actually been built (cache misses).
    /// Exposed so tests — and anyone profiling — can prove repeated
    /// consultations are cache hits, not rebuilds.
    public private(set) var buildCount = 0

    public init() {}

    /// Returns the cached entries for `fingerprint`, building (once)
    /// via `build` when the fingerprint differs from the stored one.
    public func entries(
        fingerprint: Fingerprint,
        build: @MainActor () -> [ContextIndexManager.Entry]
    ) -> [ContextIndexManager.Entry] {
        if fingerprint == storedFingerprint {
            return storedEntries
        }
        let built = build()
        storedFingerprint = fingerprint
        storedEntries = built
        buildCount += 1
        return built
    }

    /// Drops the cached entries (tests; also a safe manual invalidation).
    public func reset() {
        storedFingerprint = nil
        storedEntries = []
        buildCount = 0
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Computes the live fingerprint from the cheap signals described in
    /// the type documentation. In Chat mode the project is ignored
    /// entirely — exactly as in the index build itself — so no memory
    /// signal can leak into a Chat fingerprint.
    public static func liveFingerprint(
        mode: ContextIndexManager.Mode,
        globalCustomPrompt: String = "",
        conversationCustomPrompt: String = "",
        activeSkillIDs: Set<String> = [],
        project: AgentProject? = nil
    ) -> Fingerprint {
        let toolIDs = ToolsRegistry.shared.allTools.map(\.id).sorted().joined(separator: ",")

        let assetLines = SystemAssetsManager.shared.availableAssets().map { descriptor -> String in
            var stamp = "builtin"
            if let url = descriptor.fileURL,
               let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let modified = attributes[.modificationDate] as? Date {
                stamp = String(Int(modified.timeIntervalSince1970))
            }
            return "\(descriptor.id)|\(descriptor.filename)|\(descriptor.summary)|\(stamp)"
        }.sorted().joined(separator: "\n")

        let skillLines = SkillsManager.shared.skills
            .map { "\($0.id)|\(digest($0.fullMarkdown))" }
            .sorted()
            .joined(separator: "\n")

        let effectiveProject = mode == .agent ? (project ?? AgentProjectsStore.shared.activeProject) : nil
        let projectLine: String
        if let effectiveProject {
            let memoryDigest = digest(effectiveProject.memory.map(\.text).joined(separator: "\u{1}"))
            projectLine = "\(effectiveProject.id.uuidString)|\(effectiveProject.memory.count)|\(memoryDigest)"
        } else {
            projectLine = "none"
        }

        return Fingerprint(
            mode: mode,
            tools: digest(toolIDs),
            assets: digest(assetLines),
            skills: digest(skillLines),
            activeSkills: digest(activeSkillIDs.sorted().joined(separator: ",")),
            prompts: digest(globalCustomPrompt + "\u{1}" + conversationCustomPrompt),
            project: projectLine
        )
    }
}
