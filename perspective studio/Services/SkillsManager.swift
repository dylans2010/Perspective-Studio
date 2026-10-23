import Foundation
import SwiftUI

enum SkillSource: String, CaseIterable, Identifiable, Sendable {
    case gemini = "Gemini / Antigravity"
    case claude = "Claude"
    case chatgpt = "ChatGPT"
    case xcode = "Xcode / Dev"
    case custom = "Custom"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .gemini: "sparkles"
        case .claude: "brain.head.profile"
        case .chatgpt: "bubble.left.and.text.bubble.right.fill"
        case .xcode: "hammer.fill"
        case .custom: "folder.fill"
        }
    }

    var brandColor: Color {
        switch self {
        case .gemini: .cyan
        case .claude: .orange
        case .chatgpt: .green
        case .xcode: .blue
        case .custom: .purple
        }
    }
}

struct AgentSkill: Identifiable, Sendable, Hashable {
    let id: String
    let name: String
    let description: String
    let source: SkillSource
    let folderURL: URL
    let instructionPreview: String
    let fullMarkdown: String
    let tags: [String]

    static func == (lhs: AgentSkill, rhs: AgentSkill) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

@Observable
@MainActor
final class SkillsManager {
    static let shared = SkillsManager()

    private(set) var skills: [AgentSkill] = []
    private(set) var isScanning: Bool = false
    var searchQuery: String = ""
    var selectedSourceFilter: SkillSource? = nil

    var filteredSkills: [AgentSkill] {
        var result = skills
        if let filter = selectedSourceFilter {
            result = result.filter { $0.source == filter }
        }
        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result = result.filter {
                $0.name.localizedStandardContains(searchQuery) ||
                $0.description.localizedStandardContains(searchQuery) ||
                $0.tags.contains(where: { $0.localizedStandardContains(searchQuery) })
            }
        }
        return result
    }

    init() {
        Task {
            await scanAllSkills()
        }
    }

    func scanAllSkills() async {
        isScanning = true
        defer { isScanning = false }

        let discovered = await Task.detached(priority: .userInitiated) {
            Self.scanFileSystemSync()
        }.value

        self.skills = discovered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private nonisolated static func scanFileSystemSync() -> [AgentSkill] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        // Potential directories where ChatGPT, Claude, Gemini, Antigravity, and IDEs store skills
        let searchRoots: [(url: URL, source: SkillSource)] = [
            (home.appendingPathComponent(".gemini/config/skills"), .gemini),
            (home.appendingPathComponent(".gemini/config/plugins"), .gemini),
            (home.appendingPathComponent(".gemini/antigravity-ide/builtin/skills"), .gemini),
            (home.appendingPathComponent(".gemini/antigravity-cli/builtin/skills"), .gemini),
            (home.appendingPathComponent(".claude/skills"), .claude),
            (home.appendingPathComponent(".config/claude/skills"), .claude),
            (home.appendingPathComponent(".chatgpt/skills"), .chatgpt),
            (home.appendingPathComponent(".openai/skills"), .chatgpt),
            (home.appendingPathComponent(".config/chatgpt/skills"), .chatgpt),
            (home.appendingPathComponent(".agents/skills"), .custom),
            (home.appendingPathComponent("Library/Developer/Xcode/CodingAssistant/codex/skills"), .xcode),
            (home.appendingPathComponent("Library/Application Support/app.glaze.macos.main/agent-resources/current/skills"), .custom)
        ]

        var discovered: [AgentSkill] = []
        var seenIDs = Set<String>()

        for (rootURL, source) in searchRoots {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: rootURL.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            // Find all SKILL.md or markdown files within max depth 4
            if let enumerator = fm.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let fileURL as URL in enumerator {
                    if fileURL.lastPathComponent == "SKILL.md" || fileURL.lastPathComponent == "skill.yaml" {
                        let skillFolder = fileURL.deletingLastPathComponent()
                        let folderName = skillFolder.lastPathComponent

                        if seenIDs.contains(folderName) {
                            continue
                        }
                        seenIDs.insert(folderName)

                        if let skill = parseSkill(at: fileURL, folder: skillFolder, defaultSource: source) {
                            discovered.append(skill)
                        }
                    }
                }
            }
        }

        return discovered
    }

    private nonisolated static func parseSkill(at fileURL: URL, folder: URL, defaultSource: SkillSource) -> AgentSkill? {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }

        var name = folder.lastPathComponent
        var description = "No description provided."
        var tags: [String] = []

        // Parse YAML Frontmatter
        if content.hasPrefix("---") {
            let components = content.components(separatedBy: "---")
            if components.count >= 3 {
                let frontmatter = components[1]
                let lines = frontmatter.components(separatedBy: .newlines)
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.starts(with: "name:") {
                        name = trimmed.replacingOccurrences(of: "name:", with: "").trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
                    } else if trimmed.starts(with: "description:") {
                        description = trimmed.replacingOccurrences(of: "description:", with: "").trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
                    }
                }
            }
        } else {
            // Fallback: extract title from first header
            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.starts(with: "# ") {
                    name = trimmed.replacingOccurrences(of: "# ", with: "").trimmingCharacters(in: .whitespaces)
                    break
                }
            }
        }

        // Infer tags from name and description
        let textLower = (name + " " + description).lowercased()
        if textLower.contains("code") || textLower.contains("swift") || textLower.contains("python") || textLower.contains("dev") {
            tags.append("Coding")
        }
        if textLower.contains("debug") || textLower.contains("test") {
            tags.append("Debugging")
        }
        if textLower.contains("web") || textLower.contains("html") || textLower.contains("browser") {
            tags.append("Web")
        }
        if textLower.contains("data") || textLower.contains("sql") || textLower.contains("analytics") {
            tags.append("Data")
        }
        if textLower.contains("ai") || textLower.contains("prompt") || textLower.contains("agent") {
            tags.append("Agentic")
        }
        if tags.isEmpty {
            tags.append("Workflow")
        }

        // Determine source
        var determinedSource = defaultSource
        let pathLower = folder.path.lowercased()
        if pathLower.contains("claude") {
            determinedSource = .claude
        } else if pathLower.contains("chatgpt") || pathLower.contains("openai") {
            determinedSource = .chatgpt
        } else if pathLower.contains("gemini") || pathLower.contains("antigravity") {
            determinedSource = .gemini
        } else if pathLower.contains("xcode") {
            determinedSource = .xcode
        }

        // Preview snippet
        let preview = description.count > 140 ? String(description.prefix(137)) + "..." : description

        return AgentSkill(
            id: folder.path,
            name: name.replacingOccurrences(of: "-", with: " ").capitalized,
            description: preview,
            source: determinedSource,
            folderURL: folder,
            instructionPreview: preview,
            fullMarkdown: content,
            tags: tags
        )
    }
}
