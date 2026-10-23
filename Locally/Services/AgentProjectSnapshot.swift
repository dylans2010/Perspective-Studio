import Foundation

/// A fast, bounded snapshot of an Agent Project's folder, taken at the
/// start of a run: what kind of project it is, how it is laid out, which
/// branch it is on, and what its README says.
///
/// The agent used to start every project run blind — its context had
/// the folder *path* and nothing else, so its first several tool calls
/// were always the same orientation calls. The snapshot makes that
/// orientation part of the context itself, so the model's first tool
/// call can go straight at the task — and guarantees (with the Project
/// Tool Mandate) that exploration still happens through real tools,
/// because the snapshot deliberately covers only the top level.
public enum AgentProjectSnapshot {

    /// Directories that never describe a project's own layout.
    private nonisolated static let skippedDirectories: Set<String> = [
        ".git", ".build", "DerivedData", "node_modules", ".swiftpm", "Pods", ".idea", ".vscode"
    ]

    /// One-line summary for UI (Settings project card, project picker):
    /// kind + top-level entry count + git branch when known.
    public nonisolated static func summaryLine(for project: AgentProject) -> String {
        guard project.folderExists else { return "Folder missing" }
        let kind = detectKind(root: project.rootURL)
        let entries = topLevelEntries(root: project.rootURL)
        var parts = [kind.label, "\(entries.count) top-level item\(entries.count == 1 ? "" : "s")"]
        if let branch = gitBranch(root: project.rootURL) {
            parts.append("branch \(branch)")
        }
        return parts.joined(separator: " · ")
    }

    /// The snapshot block injected into an Agent run's context.
    public nonisolated static func contextBlock(for project: AgentProject) -> String {
        guard project.folderExists else { return "" }
        let root = project.rootURL
        let kind = detectKind(root: root)
        var lines: [String] = ["Project snapshot (taken at run start — verify details with your tools as you work):"]
        lines.append("- Kind: \(kind.label)")
        if let branch = gitBranch(root: root) {
            lines.append("- Git branch: \(branch)")
        }

        let entries = topLevelEntries(root: root)
        if !entries.isEmpty {
            lines.append("- Top level: " + entries.joined(separator: ", "))
        }

        if let count = boundedFileCount(root: root) {
            lines.append("- Files (bounded count): \(count)")
        }

        if let readme = readmeExcerpt(root: root) {
            lines.append("- README excerpt:\n\(readme)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Detection

    public nonisolated struct Kind: Sendable, Equatable {
        public var label: String
    }

    /// Project kind from its marker files, most specific first.
    public nonisolated static func detectKind(root: URL) -> Kind {
        let fm = FileManager.default
        func exists(_ relative: String) -> Bool {
            fm.fileExists(atPath: root.appending(path: relative).path)
        }
        let topNames = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        if topNames.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
            return Kind(label: "Xcode project")
        }
        if exists("Package.swift") { return Kind(label: "Swift Package") }
        if exists("package.json") { return Kind(label: "Node / JavaScript project") }
        if exists("Cargo.toml") { return Kind(label: "Rust project") }
        if exists("go.mod") { return Kind(label: "Go project") }
        if exists("pyproject.toml") || exists("requirements.txt") { return Kind(label: "Python project") }
        if exists(".git") { return Kind(label: "Git repository") }
        return Kind(label: "Folder")
    }

    /// The current branch, read from `.git/HEAD` directly — no shelling
    /// out, and a detached HEAD reports its short commit instead.
    public nonisolated static func gitBranch(root: URL) -> String? {
        let headURL = root.appending(path: ".git/HEAD")
        guard let head = try? String(contentsOf: headURL, encoding: .utf8) else { return nil }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref: refs/heads/") {
            return String(trimmed.dropFirst("ref: refs/heads/".count))
        }
        if !trimmed.isEmpty {
            return "detached at \(String(trimmed.prefix(7)))"
        }
        return nil
    }

    // MARK: - Folder reading (all bounded)

    /// Top-level entries, directories marked with a trailing slash,
    /// noise directories skipped, sorted with directories first.
    public nonisolated static func topLevelEntries(root: URL, limit: Int = 40) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        let visible = names.filter { name in
            if skippedDirectories.contains(name) { return false }
            return !name.hasPrefix(".")
        }
        let sorted = visible.sorted { a, b in
            var aDir: ObjCBool = false, bDir: ObjCBool = false
            fm.fileExists(atPath: root.appending(path: a).path, isDirectory: &aDir)
            fm.fileExists(atPath: root.appending(path: b).path, isDirectory: &bDir)
            if aDir.boolValue != bDir.boolValue { return aDir.boolValue }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        return sorted.prefix(limit).map { name in
            var isDir: ObjCBool = false
            fm.fileExists(atPath: root.appending(path: name).path, isDirectory: &isDir)
            return isDir.boolValue ? name + "/" : name
        }
    }

    /// A file count that stops early — orientation only, never a census.
    public nonisolated static func boundedFileCount(root: URL, cap: Int = 2000) -> Int? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var count = 0
        for case let url as URL in enumerator {
            if skippedDirectories.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                count += 1
                if count >= cap { return count }
            }
        }
        return count
    }

    /// The first lines of the project's README, when it has one.
    public nonisolated static func readmeExcerpt(root: URL, maxCharacters: Int = 600) -> String? {
        let candidates = ["README.md", "README", "Readme.md", "readme.md"]
        for name in candidates {
            let url = root.appending(path: name)
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                return String(trimmed.prefix(maxCharacters))
            }
        }
        return nil
    }

    /// Contents of one pinned file, bounded. Returns nil (with the reason
    /// in the context block) from the caller when the file is missing.
    public nonisolated static func pinnedFileContents(root: URL, relativePath: String, maxCharacters: Int = 3000) -> String? {
        let url = root.appending(path: relativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return String(text.prefix(maxCharacters))
    }
}
