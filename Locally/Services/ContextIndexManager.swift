import Foundation

/// The Index Manager: the single place where everything the model *could*
/// know about — tools, system assets, skills, custom system prompts, and
/// (Agent mode only) project memory — is indexed locally so that a prompt
/// only ever carries a small, budgeted selection of it.
///
/// Why this exists: prompts used to dump catalogs wholesale — every tool's
/// full schema, every asset's index line, every skill's full markdown, the
/// whole custom prompt, and up to 40 project-memory entries plus pinned
/// file contents. A local model had to read all of that before it could
/// start answering, which cost tokens and made every response slower.
///
/// The new flow:
/// - `directoryText` — counts and category names ONLY (no tool ids, no
///   per-item listing, ~160 estimated tokens at most). This is the only
///   catalog-shaped text a prompt ever gets.
/// - `retrievedBundle` — a small bundle of entries the *local* retriever
///   scored against the user's current message, hard-capped per mode
///   (600 estimated tokens in Chat, 1,600 in Agent) with per-kind
///   sub-caps. Asset bodies are never pre-injected (summaries only);
///   skill and custom-prompt payloads arrive as truncated excerpts.
/// - `search` / the `context_index_search` tool — in Agent mode the model
///   can pull full entries (e.g. one tool's complete schema) on demand,
///   mid-run, instead of receiving all of them up front.
///
/// Project memory is Agent-mode only, by construction: `buildIndex`
/// refuses to create memory entries for Chat mode no matter what the
/// caller passes, and the bundle renderer drops them again defensively.
///
/// The index itself is cheap to consult: entries precompute their token
/// sets once at build time (scoring never re-tokenizes payloads), and the
/// live index is cached behind a cheap input fingerprint
/// (`ContextIndexCache`) — repeated calls in one request reuse the built
/// entries instead of re-rendering every tool schema and re-fetching
/// every asset. Every model path (MLX and the Apple model, Chat, Agent,
/// and Quick Chat) goes through the same cached index, so the token
/// savings apply everywhere equally.
///
/// The scoring/selection/rendering core is pure and static, over value-type
/// entries, exactly like `ModelContextBuilder`; the `@MainActor`
/// convenience methods at the bottom gather the live values.
public enum ContextIndexManager {

    // MARK: - Types

    public enum Kind: String, CaseIterable, Sendable {
        case tool
        case systemAsset
        case skill
        case customPrompt
        case projectMemory

        public var label: String {
            switch self {
            case .tool: "Tool"
            case .systemAsset: "System asset"
            case .skill: "Skill"
            case .customPrompt: "Custom prompt"
            case .projectMemory: "Project memory"
            }
        }
    }

    public enum Mode: Sendable, Equatable {
        case chat
        case agent

        public var bundleTokenBudget: Int {
            switch self {
            case .chat: ContextIndexManager.chatBundleTokenBudget
            case .agent: ContextIndexManager.agentBundleTokenBudget
            }
        }
    }

    /// One indexed item. `payload` is the full text (one tool's schema, one
    /// asset's body, one skill's markdown, one custom-prompt chunk, one
    /// memory entry) — it lives in the index, on this Mac, and only ever
    /// reaches a prompt as a budgeted excerpt or an on-demand lookup.
    public struct Entry: Sendable, Equatable, Identifiable {
        public var id: String
        public var kind: Kind
        public var title: String
        public var description: String
        public var keywords: [String]
        public var payload: String
        /// Tool capability name (tools only) — feeds the directory's
        /// category list. Never a tool id.
        public var category: String?
        /// Core tools are always present in the Agent tool bundle.
        public var isCoreTool: Bool
        /// Skills the user toggled on for this conversation.
        public var isActiveSkill: Bool
        /// Stable position in the index — the deterministic tie-breaker.
        public var order: Int
        /// Token sets computed ONCE, here at index build. Scoring reads
        /// these sets; it never re-tokenizes an entry's title, keywords,
        /// description, or (potentially very large) payload per query —
        /// that per-call re-tokenization was the index's main CPU cost.
        public var preparedTokens: PreparedTokens

        /// The precomputed token sets `score(entry:queryTokens:)` reads.
        public struct PreparedTokens: Sendable, Equatable {
            public var title: Set<String>
            public var keywords: Set<String>
            public var description: Set<String>
            public var payload: Set<String>
        }

        public init(
            id: String,
            kind: Kind,
            title: String,
            description: String,
            keywords: [String] = [],
            payload: String,
            category: String? = nil,
            isCoreTool: Bool = false,
            isActiveSkill: Bool = false,
            order: Int = 0
        ) {
            self.id = id
            self.kind = kind
            self.title = title
            self.description = description
            self.keywords = keywords
            self.payload = payload
            self.category = category
            self.isCoreTool = isCoreTool
            self.isActiveSkill = isActiveSkill
            self.order = order
            self.preparedTokens = PreparedTokens(
                title: Set(ContextIndexManager.tokenize(title)),
                keywords: Set(keywords.flatMap { ContextIndexManager.tokenize($0) }),
                description: Set(ContextIndexManager.tokenize(description)),
                payload: Set(ContextIndexManager.tokenize(payload))
            )
        }
    }

    // MARK: - Budgets (named constants, enforced in code)

    /// Total estimated tokens a Chat-mode retrieved bundle may occupy.
    public static let chatBundleTokenBudget = 600
    /// Total estimated tokens an Agent-mode retrieved bundle may occupy.
    public static let agentBundleTokenBudget = 1_600
    /// Sub-cap: tool schemas inside an Agent bundle.
    public static let toolSchemaTokenBudget = 900
    /// Sub-cap: system-asset summaries (bodies are never pre-injected).
    public static let systemAssetSummaryTokenBudget = 150
    /// Sub-cap: skill excerpts.
    public static let skillTokenBudget = 350
    /// Sub-cap: custom-prompt chunks.
    public static let customPromptTokenBudget = 300
    /// Sub-cap: project-memory entries (Agent mode only).
    public static let projectMemoryTokenBudget = 300
    /// At most this many tool schemas in one Agent bundle.
    public static let maxToolSchemasInBundle = 12
    /// At most this many project-memory entries in one Agent bundle.
    public static let maxProjectMemoryEntriesInBundle = 5
    /// A skill's payload is truncated to this many characters per excerpt.
    public static let skillPayloadCharacterLimit = 1_200
    /// Total estimated tokens one `context_index_search` result may occupy.
    public static let searchResultTokenBudget = 2_500
    /// Tool ids that are always in the Agent tool bundle when present.
    public static let coreToolIDs: Set<String> = ["context_index_search", "system_asset_lookup"]
    /// The per-project memory tool joins the core set when a project is active.
    public static let projectMemoryToolID = "project_memory"

    // MARK: - Token estimation

    /// The app's one token estimate: (characterCount + 3) / 4.
    public static func estimatedTokens(for text: String) -> Int {
        (text.count + 3) / 4
    }

    /// Truncates `text` to at most `maxTokens` estimated tokens, appending
    /// `marker` (counted inside the budget) when anything was cut.
    public static func truncate(_ text: String, toEstimatedTokens maxTokens: Int, marker: String) -> String {
        guard estimatedTokens(for: text) > maxTokens else { return text }
        let charBudget = max(0, maxTokens * 4 - marker.count)
        return String(text.prefix(charBudget)) + marker
    }

    // MARK: - Tokenization & scoring

    private static let stopwords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "what", "when",
        "where", "which", "have", "has", "had", "can", "could", "should",
        "would", "will", "you", "your", "our", "are", "was", "were", "been",
        "does", "did", "into", "about", "please", "help", "show", "tell",
        "give", "make", "need", "want", "using", "use", "used", "how", "why",
        "any", "all", "not", "but", "its", "it"
    ]

    /// Lowercased word tokens of length ≥ 3, stopwords removed, order kept,
    /// duplicates removed. Used for queries and entry text alike.
    public static func tokenize(_ text: String) -> [String] {
        var seen = Set<String>()
        var tokens: [String] = []
        for raw in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }) {
            let token = String(raw)
            guard token.count >= 3, !stopwords.contains(token), !seen.contains(token) else { continue }
            seen.insert(token)
            tokens.append(token)
        }
        return tokens
    }

    /// The pieces of one entry's score, kept separate because retrieval
    /// decisions need more than the total: a single payload hit from a
    /// common word ("there", "hello") is noise, not relevance.
    public struct ScoreComponents: Sendable, Equatable {
        /// Title/keyword/description/payload match points, boosts excluded.
        public var lexical: Int
        /// Standing-instruction / active-skill priority, when it applies.
        public var boost: Int
        public var total: Int { lexical + boost }
        /// True when a title, keyword, or description token matched.
        public var hasStrongHit: Bool
        /// Distinct query tokens found in the payload (capped evidence).
        public var payloadHits: Int
    }

    public static func scoreComponents(entry: Entry, queryTokens: [String]) -> ScoreComponents {
        // Precomputed at index build — scoring is pure set lookups, so
        // consulting the index costs almost nothing per request.
        let prepared = entry.preparedTokens
        var lexical = 0
        var payloadHits = 0
        var strongHit = false
        for token in queryTokens {
            if prepared.title.contains(token) { lexical += 10; strongHit = true }
            if prepared.keywords.contains(token) { lexical += 6; strongHit = true }
            if prepared.description.contains(token) { lexical += 3; strongHit = true }
            if prepared.payload.contains(token) { payloadHits += 1 }
        }
        // Payload evidence is weak and capped, so a long document cannot
        // outrank a title/keyword match just by mentioning everything.
        lexical += min(payloadHits, 5)

        var boost = 0
        if entry.kind == .customPrompt {
            // The user's standing instructions: always eligible (within
            // their sub-budget), relevant or not — they are instructions
            // the user explicitly configured, not retrieved content.
            boost = 500
        } else if entry.kind == .skill && entry.isActiveSkill && lexical > 0 {
            // An *activated* skill is prioritized only when the message
            // actually relates to it. The old unconditional +300 injected
            // every active skill's excerpt into every turn — including
            // "hello" — which is how skill text ended up recited as a
            // greeting response.
            boost = 300
        }
        return ScoreComponents(lexical: lexical, boost: boost, hasStrongHit: strongHit, payloadHits: payloadHits)
    }

    /// Deterministic lexical score of one entry against tokenized query
    /// terms: title matches weigh most, then keywords/tags, then the
    /// description, then the payload, plus the priority boosts described
    /// in `scoreComponents`.
    public static func score(entry: Entry, queryTokens: [String]) -> Int {
        scoreComponents(entry: entry, queryTokens: queryTokens).total
    }

    /// Whether an entry is relevant enough to retrieve for this query.
    /// A bare score > 0 is NOT sufficient: one payload hit on a common
    /// word must not pull a skill, asset, or schema into the prompt.
    /// Relevance requires a strong (title/keyword/description) hit, at
    /// least two distinct payload-token hits, or standing status
    /// (custom-prompt chunks; core tools are handled by the caller).
    public static func isRelevant(entry: Entry, queryTokens: [String]) -> Bool {
        if entry.kind == .customPrompt { return true }
        let components = scoreComponents(entry: entry, queryTokens: queryTokens)
        guard components.lexical > 0 else { return false }
        return components.hasStrongHit || components.payloadHits >= 2
    }

    // MARK: - Index building (pure)

    /// Builds index entries from live-shaped values. Memory entries are
    /// created ONLY in Agent mode: in Chat mode the `project` argument is
    /// ignored entirely, so a Chat index containing memory is impossible
    /// to construct through this API.
    public static func buildIndex(
        tools: [any AssistTool],
        assets: [SystemAssetDescriptor],
        assetContent: (String) -> String?,
        skills: [AgentSkill],
        activeSkillIDs: Set<String> = [],
        globalCustomPrompt: String = "",
        conversationCustomPrompt: String = "",
        project: AgentProject? = nil,
        mode: Mode
    ) -> [Entry] {
        var entries: [Entry] = []
        var order = 0
        func nextOrder() -> Int { defer { order += 1 }; return order }

        for tool in tools {
            entries.append(Entry(
                id: "tool:\(tool.id)",
                kind: .tool,
                title: tool.name,
                description: tool.description,
                keywords: [tool.capability.rawValue],
                payload: ToolsRegistry.schemaDescription(for: tool),
                category: tool.capability.rawValue,
                isCoreTool: coreToolIDs.contains(tool.id),
                order: nextOrder()
            ))
        }

        for asset in assets {
            entries.append(Entry(
                id: "systemAsset:\(asset.id)",
                kind: .systemAsset,
                title: asset.name,
                description: asset.summary,
                keywords: asset.tags + [asset.topic],
                payload: assetContent(asset.id) ?? asset.summary,
                order: nextOrder()
            ))
        }

        for skill in skills {
            entries.append(Entry(
                id: "skill:\(skill.id)",
                kind: .skill,
                title: skill.name,
                description: skill.description,
                keywords: skill.tags,
                payload: skill.fullMarkdown,
                isActiveSkill: activeSkillIDs.contains(skill.id),
                order: nextOrder()
            ))
        }

        for entry in customPromptEntries(global: globalCustomPrompt, conversation: conversationCustomPrompt, startingOrder: order) {
            entries.append(entry)
            order += 1
        }

        // Agent mode ONLY — see the doc comment above. There is no code
        // path from a Chat-mode call to a memory entry.
        if mode == .agent, let project {
            for memory in project.memoryNewestFirst {
                entries.append(Entry(
                    id: "projectMemory:\(memory.id.uuidString)",
                    kind: .projectMemory,
                    title: memory.kind.label,
                    description: "",
                    payload: memory.text,
                    order: nextOrder()
                ))
            }
        }

        return entries
    }

    /// Chunks a custom prompt on paragraph and heading boundaries. Each
    /// chunk becomes one entry whose title is its first line. An exact
    /// duplicate conversation prompt (ChatDetailView copies the global
    /// prompt into new conversations) is indexed once.
    public static func customPromptEntries(global: String, conversation: String, startingOrder: Int = 0) -> [Entry] {
        var entries: [Entry] = []
        var order = startingOrder
        let globalTrimmed = global.trimmingCharacters(in: .whitespacesAndNewlines)
        let conversationTrimmed = conversation.trimmingCharacters(in: .whitespacesAndNewlines)

        func addChunks(of text: String, sourceLabel: String) {
            for chunk in chunkCustomPrompt(text) {
                let firstLine = chunk.components(separatedBy: .newlines).first ?? ""
                entries.append(Entry(
                    id: "customPrompt:\(sourceLabel):\(order)",
                    kind: .customPrompt,
                    title: String(firstLine.prefix(80)),
                    description: sourceLabel,
                    payload: chunk,
                    order: order
                ))
                order += 1
            }
        }

        if !globalTrimmed.isEmpty { addChunks(of: globalTrimmed, sourceLabel: "Global") }
        if !conversationTrimmed.isEmpty && conversationTrimmed != globalTrimmed {
            addChunks(of: conversationTrimmed, sourceLabel: "Conversation")
        }
        return entries
    }

    /// Splits prompt text into chunks: a heading line or a blank line ends
    /// the current chunk, and an over-long chunk is hard-split so no single
    /// entry can blow a sub-budget on its own.
    public static func chunkCustomPrompt(_ text: String) -> [String] {
        var chunks: [String] = []
        var current: [String] = []
        func flush() {
            let joined = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            current = []
            guard !joined.isEmpty else { return }
            if joined.count <= 2_000 {
                chunks.append(joined)
            } else {
                var remaining = joined
                while remaining.count > 2_000 {
                    chunks.append(String(remaining.prefix(2_000)))
                    remaining = String(remaining.dropFirst(2_000))
                }
                if !remaining.isEmpty { chunks.append(remaining) }
            }
        }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flush()
            } else if trimmed.hasPrefix("#") && !current.isEmpty {
                flush()
                current.append(line)
            } else {
                current.append(line)
            }
        }
        flush()
        return chunks
    }

    // MARK: - Directory (pure)

    /// The tiny directory a prompt may carry: counts and tool category
    /// names ONLY — no tool ids, no per-item names, no summaries. Derived
    /// from the entries, so what it counts is exactly what is indexed.
    public static func directoryText(entries: [Entry], mode: Mode) -> String {
        let toolEntries = entries.filter { $0.kind == .tool }
        let assetCount = entries.filter { $0.kind == .systemAsset }.count
        let skillCount = entries.filter { $0.kind == .skill }.count
        let promptChunkCount = entries.filter { $0.kind == .customPrompt }.count

        let presentCategories = Set(toolEntries.compactMap(\.category))
        let categories = ToolCapability.allCases.map(\.rawValue).filter { presentCategories.contains($0) }

        var lines: [String] = [
            "[Context Directory]",
            "Everything below is indexed locally on this Mac. Only these counts are ever in a prompt — full entries are never sent wholesale; a small selection is retrieved per message, and full text is retrievable on demand in Agent mode."
        ]
        if toolEntries.isEmpty {
            lines.append("Tools: 0.")
        } else if categories.isEmpty {
            lines.append("Tools: \(toolEntries.count).")
        } else {
            lines.append("Tools: \(toolEntries.count) across \(categories.joined(separator: ", ")).")
        }
        lines.append("System assets: \(assetCount). Skills: \(skillCount). Custom prompt chunks: \(promptChunkCount).")
        if mode == .agent {
            let memoryCount = entries.filter { $0.kind == .projectMemory }.count
            lines.append("Project memory entries: \(memoryCount) (Agent mode only).")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Retrieval & bundle rendering (pure)

    private static func subBudget(for kind: Kind, mode: Mode) -> Int {
        switch kind {
        case .tool: toolSchemaTokenBudget
        case .systemAsset: systemAssetSummaryTokenBudget
        case .skill: skillTokenBudget
        case .customPrompt: customPromptTokenBudget
        case .projectMemory: projectMemoryTokenBudget
        }
    }

    /// Allocation order: the user's standing instructions first (they must
    /// never be crowded out), then tools, skills, asset summaries, memory.
    private static let allocationOrder: [Kind] = [.customPrompt, .tool, .skill, .systemAsset, .projectMemory]

    /// Scored candidates for one kind, best first, ties broken by index
    /// order so selection is deterministic. Zero-score entries excluded.
    /// Core tools lead the tool list regardless of score (Agent mode).
    private static func candidates(
        entries: [Entry],
        kind: Kind,
        queryTokens: [String],
        hasActiveProject: Bool
    ) -> [Entry] {
        let ofKind = entries.filter { $0.kind == kind }
        guard kind == .tool else {
            let scoredEntries: [(entry: Entry, score: Int)] = ofKind.compactMap { entry in
                let s = score(entry: entry, queryTokens: queryTokens)
                return (s > 0 && isRelevant(entry: entry, queryTokens: queryTokens)) ? (entry: entry, score: s) : nil
            }
            let sortedEntries = scoredEntries.sorted { lhs, rhs in
                lhs.score != rhs.score ? lhs.score > rhs.score : lhs.entry.order < rhs.entry.order
            }
            return sortedEntries.map(\.entry)
        }
        func isCore(_ entry: Entry) -> Bool {
            entry.isCoreTool || (hasActiveProject && entry.id == "tool:\(projectMemoryToolID)")
        }
        let core = ofKind.filter(isCore).sorted { $0.order < $1.order }
        let nonCore = ofKind.filter { !isCore($0) }
        let scoredNonCore: [(entry: Entry, score: Int)] = nonCore.compactMap { entry in
            let s = score(entry: entry, queryTokens: queryTokens)
            return (s > 0 && isRelevant(entry: entry, queryTokens: queryTokens)) ? (entry: entry, score: s) : nil
        }
        let sortedNonCore = scoredNonCore.sorted { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.entry.order < rhs.entry.order
        }
        let scored = sortedNonCore.map(\.entry)
        return core + scored
    }

    /// Renders one entry as its bundle piece. Asset pieces are the summary
    /// line ONLY — the body is never pre-injected. Skill payloads are
    /// truncated to `payloadCharLimit` with a retrieval note.
    private static func piece(for entry: Entry, payloadCharLimit: Int? = nil) -> String {
        switch entry.kind {
        case .tool:
            return entry.payload
        case .systemAsset:
            return "- \(entry.title): \(entry.description)"
        case .skill:
            let limit = payloadCharLimit ?? skillPayloadCharacterLimit
            if entry.payload.count > limit {
                return "### Skill: \(entry.title)\n\(String(entry.payload.prefix(limit)))\n[Excerpt only — the full skill text is retrievable on demand in Agent mode.]"
            }
            return "### Skill: \(entry.title)\n\(entry.payload)"
        case .customPrompt:
            if let limit = payloadCharLimit, entry.payload.count > limit {
                return "Custom instructions excerpt (\(entry.description)):\n\(String(entry.payload.prefix(limit)))\n[Excerpt only — further chunks are retrievable on demand in Agent mode.]"
            }
            return "Custom instructions excerpt (\(entry.description)):\n\(entry.payload)"
        case .projectMemory:
            if let limit = payloadCharLimit, entry.payload.count > limit {
                return "- [\(entry.title)] \(String(entry.payload.prefix(limit)))…"
            }
            return "- [\(entry.title)] \(entry.payload)"
        }
    }

    private static func sectionHeader(for kind: Kind) -> String {
        switch kind {
        case .tool: return "### Retrieved tool schemas (call with the TOOL_CALL format)"
        case .systemAsset: return "### Retrieved system asset summaries (full text on demand in Agent mode)"
        case .skill: return "### Retrieved skill excerpts"
        case .customPrompt: return "### Retrieved custom instructions — set by the user, follow them"
        case .projectMemory: return "### Retrieved project memory (Agent mode only)"
        }
    }

    private static func defaultPayloadLimit(for kind: Kind) -> Int? {
        kind == .skill ? skillPayloadCharacterLimit : nil
    }

    /// Selects and renders one kind's section within its sub-budget and
    /// the remaining total budget, measuring the actual rendered text.
    /// Returns nil when nothing fits / nothing was retrieved.
    private static func renderSection(
        kind: Kind,
        candidates: [Entry],
        mode: Mode,
        remainingTotal: Int
    ) -> String? {
        let cap = min(subBudget(for: kind, mode: mode), remainingTotal)
        guard cap > 0 else { return nil }
        let header = sectionHeader(for: kind)
        var pieces: [String] = []
        var included = 0
        for entry in candidates {
            if kind == .tool && included >= maxToolSchemasInBundle { break }
            if kind == .projectMemory && included >= maxProjectMemoryEntriesInBundle { break }
            let candidate = piece(for: entry, payloadCharLimit: defaultPayloadLimit(for: kind))
            let trial = ([header] + pieces + [candidate]).joined(separator: "\n")
            if estimatedTokens(for: trial) <= cap {
                pieces.append(candidate)
                included += 1
                continue
            }
            // Truncatable kinds: shrink this entry to fit rather than
            // dropping the user's instructions / an active skill entirely.
            if kind == .skill || kind == .customPrompt || kind == .projectMemory {
                let overhead = piece(for: entry, payloadCharLimit: 0).count + header.count + pieces.joined(separator: "\n").count + 16
                let availableChars = cap * 4 - overhead
                if availableChars >= 200 {
                    let shrunk = piece(for: entry, payloadCharLimit: availableChars)
                    let shrunkTrial = ([header] + pieces + [shrunk]).joined(separator: "\n")
                    if estimatedTokens(for: shrunkTrial) <= cap {
                        pieces.append(shrunk)
                        included += 1
                        continue
                    }
                }
            }
            // Sequential kinds (custom-prompt chunks, memory entries) are
            // parts of one ordered document: stop at the first entry that
            // doesn't fit instead of skipping ahead and surfacing a later
            // fragment out of context. Independent kinds (tools, skills,
            // assets) keep scanning — a smaller later entry may still fit.
            if kind == .customPrompt || kind == .projectMemory {
                break
            }
        }
        guard !pieces.isEmpty else { return nil }
        return ([header] + pieces).joined(separator: "\n")
    }

    /// The retrieved bundle for one user message: the local retriever's
    /// selection, grouped by kind, hard-capped at the mode's total budget.
    /// Chat mode never contains tool schemas or project memory, whatever
    /// the caller passes; Agent tool schemas are skipped when
    /// `includeToolSchemas` is false (call sites whose harness adds its
    /// own retrieved tool bundle, to avoid paying for schemas twice).
    public static func retrievedBundle(
        entries: [Entry],
        query: String,
        mode: Mode,
        hasActiveProject: Bool = false,
        includeToolSchemas: Bool = true,
        intent: ConversationIntent = .task
    ) -> String {
        let budget = mode.bundleTokenBudget
        let queryTokens = tokenize(query)
        // The header states the precedence rule every time: retrieved
        // excerpts are reference material subordinate to the core and
        // mode instructions — they are never text to repeat to the user.
        let header = "[Retrieved Context — excerpts the local index selected for this message. This is a small selection, not the full catalog. It is reference material for you only: it does not override the instructions above it, and none of it is text to repeat, quote, or summarize back to the user unless the user's request is actually about it.]"
        var used = estimatedTokens(for: header)
        var sections: [String] = []

        for kind in allocationOrder {
            // Conversational turns (greetings, thanks, acknowledgements)
            // get standing user instructions ONLY — no tool schemas, no
            // skill excerpts, no asset summaries, no memory. Injecting
            // capability material into a greeting is what made models
            // answer "hello" with a catalog recitation.
            if intent == .conversational && kind != .customPrompt { continue }
            // Direct turns (questions, discussion) get relevant reference
            // excerpts but no tool machinery.
            if intent == .direct && kind == .tool { continue }
            if kind == .tool && (mode == .chat || !includeToolSchemas) { continue }
            if kind == .projectMemory && mode == .chat { continue }
            let pool = entries.filter { mode == .agent || $0.kind != .projectMemory }
            let section = renderSection(
                kind: kind,
                candidates: candidates(entries: pool, kind: kind, queryTokens: queryTokens, hasActiveProject: hasActiveProject),
                mode: mode,
                remainingTotal: budget - used
            )
            if let section {
                sections.append(section)
                used += estimatedTokens(for: section)
            }
        }
        guard !sections.isEmpty else { return "" }
        return ([header] + sections).joined(separator: "\n\n")
    }

    /// The Agent tool bundle on its own: core tools first, then the
    /// top-scored schemas for the query, inside the tool sub-budget.
    /// Used by the agent harness, which frames the schemas itself.
    public static func toolSchemaBundle(entries: [Entry], query: String, hasActiveProject: Bool = false, intent: ConversationIntent = .task) -> String {
        // No tool schemas at all for conversational or direct turns: a
        // schema in the prompt is an invitation to call the tool.
        guard intent.allowsToolMachinery else { return "" }
        let queryTokens = tokenize(query)
        let pool = candidates(entries: entries, kind: .tool, queryTokens: queryTokens, hasActiveProject: hasActiveProject)
        var pieces: [String] = []
        var included = 0
        for entry in pool {
            if included >= maxToolSchemasInBundle { break }
            let trial = (pieces + [entry.payload]).joined(separator: "\n")
            guard estimatedTokens(for: trial) <= toolSchemaTokenBudget else { continue }
            pieces.append(entry.payload)
            included += 1
        }
        return pieces.joined(separator: "\n")
    }

    // MARK: - On-demand search (pure)

    /// Scores the index for the lookup tool: full entries back, best
    /// first, zero-score excluded, at most `limit` (clamped to 1...8).
    public static func search(entries: [Entry], query: String, kind: Kind? = nil, limit: Int = 5) -> [Entry] {
        let queryTokens = tokenize(query)
        let pool: [Entry]
        if let kind {
            pool = entries.filter { $0.kind == kind }
        } else {
            pool = entries
        }
        let scoredEntries: [(entry: Entry, score: Int)] = pool.compactMap { entry in
            let s = score(entry: entry, queryTokens: queryTokens)
            return (s > 0 && isRelevant(entry: entry, queryTokens: queryTokens)) ? (entry: entry, score: s) : nil
        }
        let sortedEntries = scoredEntries.sorted { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.entry.order < rhs.entry.order
        }
        let maxCount = max(1, min(limit, 8))
        return Array(sortedEntries.prefix(maxCount).map(\.entry))
    }

    // MARK: - Retrieval diagnostics (developer visibility)

    /// One entry's retrieval decision for a query, WITHOUT any payload:
    /// ids, kinds, scores, and the reason — safe to show in developer
    /// diagnostics, never rendered into a chat message.
    public struct RetrievalDiagnostic: Sendable, Equatable {
        public var entryID: String
        public var kind: Kind
        public var score: Int
        public var selected: Bool
        public var reason: String
    }

    /// Explains, per indexed entry, whether the bundle selection for
    /// this query would select it and why. Mirrors `candidates` +
    /// the intent gates in `retrievedBundle` (budget trimming can still
    /// drop a selected entry; the reason says so).
    public static func retrievalDiagnostics(
        entries: [Entry],
        query: String,
        mode: Mode,
        intent: ConversationIntent = .task,
        hasActiveProject: Bool = false
    ) -> [RetrievalDiagnostic] {
        let queryTokens = tokenize(query)
        return entries.map { entry in
            let s = score(entry: entry, queryTokens: queryTokens)
            func diag(_ selected: Bool, _ reason: String) -> RetrievalDiagnostic {
                RetrievalDiagnostic(entryID: entry.id, kind: entry.kind, score: s, selected: selected, reason: reason)
            }
            if intent == .conversational && entry.kind != .customPrompt {
                return diag(false, "excluded: conversational turn retrieves standing instructions only")
            }
            if intent == .direct && entry.kind == .tool {
                return diag(false, "excluded: direct turn is not offered tool schemas")
            }
            if mode == .chat && (entry.kind == .tool || entry.kind == .projectMemory) {
                return diag(false, "excluded: \(entry.kind.label) never enters a Chat prompt")
            }
            if entry.kind == .customPrompt {
                return diag(true, "standing user instructions (always eligible, sub-budget applies)")
            }
            if entry.kind == .tool && (entry.isCoreTool || (hasActiveProject && entry.id == "tool:\(projectMemoryToolID)")) {
                return diag(intent.allowsToolMachinery, intent.allowsToolMachinery ? "core tool for task turns" : "core tool withheld: not a task turn")
            }
            if s <= 0 {
                return diag(false, "no lexical match")
            }
            if !isRelevant(entry: entry, queryTokens: queryTokens) {
                return diag(false, "weak match only (single payload hit) — below the relevance gate")
            }
            return diag(true, "lexical match, score \(s) (budget trimming may still apply)")
        }
    }

    /// Renders search results with their FULL payloads (a tool match
    /// returns that tool's complete schema, so the model can then call
    /// it), capped at the search budget in total.
    public static func renderSearchResults(_ results: [Entry]) -> String {
        guard !results.isEmpty else { return "No indexed entries matched that query." }
        var blocks: [String] = []
        var used = 0
        for entry in results {
            let block = "### \(entry.kind.label): \(entry.title)\n\(entry.payload)"
            let blockTokens = estimatedTokens(for: block)
            if used + blockTokens <= searchResultTokenBudget {
                blocks.append(block)
                used += blockTokens
            } else {
                let remainingChars = (searchResultTokenBudget - used) * 4 - entry.title.count - 80
                if remainingChars >= 200 {
                    blocks.append("### \(entry.kind.label): \(entry.title)\n\(String(entry.payload.prefix(remainingChars)))\n[Truncated — this entry is larger than the per-lookup budget.]")
                }
                break
            }
        }
        return blocks.joined(separator: "\n\n")
    }
}

// MARK: - Live gathering (@MainActor convenience)

extension ContextIndexManager {

    /// Builds the index from the live registries/managers — through the
    /// `ContextIndexCache`, so the expensive build (rendering every
    /// tool's schema text, fetching every asset's content, tokenizing
    /// every payload) happens only when a cheap fingerprint of the
    /// inputs changes. One request typically asks for the index several
    /// times (directory + bundle, sometimes on two prompt paths); with
    /// unchanged inputs those are all the same cached build. In Chat
    /// mode the active project is deliberately NOT consulted — memory
    /// entries cannot enter a Chat index.
    @MainActor
    public static func liveEntries(
        mode: Mode,
        globalCustomPrompt: String = "",
        conversationCustomPrompt: String = "",
        activeSkillIDs: Set<String> = [],
        project: AgentProject? = nil
    ) -> [Entry] {
        let fingerprint = ContextIndexCache.liveFingerprint(
            mode: mode,
            globalCustomPrompt: globalCustomPrompt,
            conversationCustomPrompt: conversationCustomPrompt,
            activeSkillIDs: activeSkillIDs,
            project: project
        )
        return ContextIndexCache.shared.entries(fingerprint: fingerprint) {
            let effectiveProject = mode == .agent ? (project ?? AgentProjectsStore.shared.activeProject) : nil
            // Asset payloads are fetched here, on the main actor, so the
            // closure handed to the pure builder captures only a Sendable
            // dictionary — never the (main-actor) assets manager itself.
            let descriptors = SystemAssetsManager.shared.availableAssets()
            var assetContents: [String: String] = [:]
            for descriptor in descriptors {
                if let content = SystemAssetsManager.shared.fetchAssetContent(named: descriptor.id) {
                    assetContents[descriptor.id] = content
                }
            }
            return buildIndex(
                tools: ToolsRegistry.shared.allTools,
                assets: descriptors,
                assetContent: { assetContents[$0] },
                skills: SkillsManager.shared.skills,
                activeSkillIDs: activeSkillIDs,
                globalCustomPrompt: globalCustomPrompt,
                conversationCustomPrompt: conversationCustomPrompt,
                project: effectiveProject,
                mode: mode
            )
        }
    }

    @MainActor
    public static func directoryText(
        mode: Mode,
        globalCustomPrompt: String = "",
        conversationCustomPrompt: String = "",
        activeSkillIDs: Set<String> = [],
        project: AgentProject? = nil
    ) -> String {
        directoryText(
            entries: liveEntries(mode: mode, globalCustomPrompt: globalCustomPrompt, conversationCustomPrompt: conversationCustomPrompt, activeSkillIDs: activeSkillIDs, project: project),
            mode: mode
        )
    }

    @MainActor
    public static func retrievedBundle(
        query: String,
        mode: Mode,
        globalCustomPrompt: String = "",
        conversationCustomPrompt: String = "",
        activeSkillIDs: Set<String> = [],
        project: AgentProject? = nil,
        includeToolSchemas: Bool = true,
        intent: ConversationIntent = .task
    ) -> String {
        let entries = liveEntries(
            mode: mode,
            globalCustomPrompt: globalCustomPrompt,
            conversationCustomPrompt: conversationCustomPrompt,
            activeSkillIDs: activeSkillIDs,
            project: project
        )
        let hasProject = mode == .agent && (project ?? AgentProjectsStore.shared.activeProject) != nil
        return retrievedBundle(entries: entries, query: query, mode: mode, hasActiveProject: hasProject, includeToolSchemas: includeToolSchemas, intent: intent)
    }

    /// The Agent harness's tool bundle, gathered live for the run's prompt.
    @MainActor
    public static func agentToolSchemaBundle(query: String, hasActiveProject: Bool, intent: ConversationIntent = .task) -> String {
        toolSchemaBundle(entries: liveEntries(mode: .agent), query: query, hasActiveProject: hasActiveProject, intent: intent)
    }
}
