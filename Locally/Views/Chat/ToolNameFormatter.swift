import Foundation

/// Systematically humanizes raw tool identifiers into user-friendly progressive action titles.
/// Never exposes raw snake_case or technical tool identifiers in the UI.
public enum ToolNameFormatter {
    /// Explicit overrides for known or custom tools requiring bespoke phrasing.
    private nonisolated static let explicitOverrides: [String: String] = [
        "calculator": "Calculating Expression",
        "calc": "Calculating Expression",
        "hardware_info": "Checking Mac Hardware Info",
        "mac_hardware_info": "Checking Mac Hardware Info",
        "date_time": "Checking Date & Time",
        "datetime": "Checking Date & Time",
        "date": "Checking Date & Time",
        "time": "Checking Current Time",
        "model_library": "Checking Model Library",
        "file_search": "Searching File",
        "search_file": "Searching File",
        "file_create": "Creating File",
        "create_file": "Creating File",
        "file_append": "Appending to File",
        "append_file": "Appending to File",
        "search_skills": "Searching Skills",
        "skills_search": "Searching Skills",
        "read_file": "Reading File",
        "file_read": "Reading File",
        "workspace_search": "Searching Workspace",
        "search_workspace": "Searching Workspace",
        "code_symbol_index": "Indexing Code Symbols",
        "index_code_symbols": "Indexing Code Symbols",
        "audit_access_levels": "Auditing Access Levels"
    ]

    /// Explicit overrides for completed past-tense action titles.
    private nonisolated static let explicitCompletedOverrides: [String: String] = [
        "calculator": "Calculated Expression",
        "calc": "Calculated Expression",
        "hardware_info": "Checked Mac Hardware Info",
        "mac_hardware_info": "Checked Mac Hardware Info",
        "date_time": "Checked Date & Time",
        "datetime": "Checked Date & Time",
        "model_library": "Checked Model Library",
        "file_search": "Searched File",
        "search_file": "Searched File",
        "file_create": "Created File",
        "create_file": "Created File",
        "file_append": "Appended to File",
        "append_file": "Appended to File",
        "search_skills": "Searched Skills",
        "skills_search": "Searched Skills",
        "read_file": "Read File",
        "file_read": "Read File",
        "workspace_search": "Searched Workspace",
        "search_workspace": "Searched Workspace",
        "code_symbol_index": "Indexed Code Symbols",
        "index_code_symbols": "Indexed Code Symbols",
        "audit_access_levels": "Audited Access Levels"
    ]

    /// Dictionary mapping base verb lemmas to their present participle (-ing) form.
    private nonisolated static let verbParticiples: [String: String] = [
        "create": "Creating",
        "make": "Creating",
        "read": "Reading",
        "write": "Writing",
        "get": "Getting",
        "fetch": "Fetching",
        "list": "Listing",
        "search": "Searching",
        "find": "Finding",
        "check": "Checking",
        "inspect": "Inspecting",
        "audit": "Auditing",
        "run": "Running",
        "test": "Testing",
        "build": "Building",
        "delete": "Deleting",
        "remove": "Removing",
        "update": "Updating",
        "modify": "Modifying",
        "append": "Appending",
        "extract": "Extracting",
        "analyze": "Analyzing",
        "analyse": "Analyzing",
        "format": "Formatting",
        "validate": "Validating",
        "verify": "Verifying",
        "execute": "Executing",
        "generate": "Generating",
        "index": "Indexing",
        "calculate": "Calculating",
        "calc": "Calculating",
        "scan": "Scanning",
        "load": "Loading",
        "view": "Viewing",
        "download": "Downloading",
        "upload": "Uploading",
        "install": "Installing",
        "compile": "Compiling",
        "edit": "Editing",
        "open": "Opening",
        "close": "Closing",
        "save": "Saving",
        "clean": "Cleaning",
        "filter": "Filtering",
        "parse": "Parsing",
        "transform": "Transforming",
        "sync": "Syncing",
        "show": "Showing",
        "start": "Starting",
        "stop": "Stopping",
        "listen": "Listening",
        "connect": "Connecting",
        "query": "Querying",
        "benchmark": "Benchmarking",
        "profile": "Profiling"
    ]

    /// Dictionary mapping base verb lemmas to their past tense form.
    private nonisolated static let verbPastTense: [String: String] = [
        "create": "Created",
        "make": "Created",
        "read": "Read",
        "write": "Wrote",
        "get": "Got",
        "fetch": "Fetched",
        "list": "Listed",
        "search": "Searched",
        "find": "Found",
        "check": "Checked",
        "inspect": "Inspected",
        "audit": "Audited",
        "run": "Ran",
        "test": "Tested",
        "build": "Built",
        "delete": "Deleted",
        "remove": "Removed",
        "update": "Updated",
        "modify": "Modified",
        "append": "Appended",
        "extract": "Extracted",
        "analyze": "Analyzed",
        "analyse": "Analyzed",
        "format": "Formatted",
        "validate": "Validated",
        "verify": "Verified",
        "execute": "Executed",
        "generate": "Generated",
        "index": "Indexed",
        "calculate": "Calculated",
        "calc": "Calculated",
        "scan": "Scanned",
        "load": "Loaded",
        "view": "Viewed",
        "download": "Downloaded",
        "upload": "Uploaded",
        "install": "Installed",
        "compile": "Compiled",
        "edit": "Edited",
        "open": "Opened",
        "close": "Closed",
        "save": "Saved",
        "clean": "Cleaned",
        "filter": "Filtered",
        "parse": "Parsed",
        "transform": "Transformed",
        "sync": "Synced",
        "show": "Showed",
        "start": "Started",
        "stop": "Stopped",
        "listen": "Listened",
        "connect": "Connected",
        "query": "Queried"
    ]

    // MARK: - Public API

    /// Formats any tool identifier into a progressive action phrase (e.g. "create_file" -> "Creating File").
    public nonisolated static func format(_ rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Using Tool" }

        let normalized = trimmed.lowercased().replacingOccurrences(of: "-", with: "_")
        if let override = explicitOverrides[normalized] {
            return override
        }

        let tokens = tokenize(trimmed)
        guard !tokens.isEmpty else { return "Using Tool" }

        // 1. Check trailing verb (e.g. file_search -> Searching File, file_create -> Creating File)
        if tokens.count > 1, let lastToken = tokens.last, let verbParticiple = participle(for: lastToken) {
            let nounTokens = tokens.dropLast()
            return assemble(verb: lastToken.lowercased(), participle: verbParticiple, nouns: Array(nounTokens))
        }

        // 2. Check leading verb (e.g. create_file -> Creating File, search_skills -> Searching Skills)
        if let firstToken = tokens.first, let verbParticiple = participle(for: firstToken) {
            let nounTokens = tokens.dropFirst()
            return assemble(verb: firstToken.lowercased(), participle: verbParticiple, nouns: Array(nounTokens))
        }

        // 3. Check embedded verb (e.g. quick_file_search -> Searching Quick File)
        if let verbIndex = tokens.firstIndex(where: { participle(for: $0) != nil }) {
            let verbToken = tokens[verbIndex]
            let verbParticiple = participle(for: verbToken)!
            var remaining = tokens
            remaining.remove(at: verbIndex)
            return assemble(verb: verbToken.lowercased(), participle: verbParticiple, nouns: remaining)
        }

        // 4. Fallback when no known verb is detected
        let title = formatNouns(tokens)
        return "Using \(title)"
    }

    /// Formats a tool identifier into a completed past-tense action phrase (e.g. "create_file" -> "Created File").
    public nonisolated static func completedTitle(for rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Used Tool" }

        let normalized = trimmed.lowercased().replacingOccurrences(of: "-", with: "_")
        if let override = explicitCompletedOverrides[normalized] {
            return override
        }

        let tokens = tokenize(trimmed)
        guard !tokens.isEmpty else { return "Used Tool" }

        if tokens.count > 1, let lastToken = tokens.last, let past = pastTense(for: lastToken) {
            let nounTokens = tokens.dropLast()
            return assemble(verb: lastToken.lowercased(), participle: past, nouns: Array(nounTokens))
        }

        if let firstToken = tokens.first, let past = pastTense(for: firstToken) {
            let nounTokens = tokens.dropFirst()
            return assemble(verb: firstToken.lowercased(), participle: past, nouns: Array(nounTokens))
        }

        if let verbIndex = tokens.firstIndex(where: { pastTense(for: $0) != nil }) {
            let verbToken = tokens[verbIndex]
            let past = pastTense(for: verbToken)!
            var remaining = tokens
            remaining.remove(at: verbIndex)
            return assemble(verb: verbToken.lowercased(), participle: past, nouns: remaining)
        }

        let title = formatNouns(tokens)
        return "Used \(title)"
    }

    /// Returns an appropriate SF Symbol icon name for the given tool.
    public nonisolated static func iconName(for rawName: String) -> String {
        let normalized = rawName.lowercased().replacingOccurrences(of: "-", with: "_")
        
        if normalized.contains("calc") {
            return "plus.forwardslash.minus"
        }
        if normalized.contains("date") || normalized.contains("time") || normalized.contains("clock") {
            return "clock.fill"
        }
        if normalized.contains("hardware") || normalized.contains("ram") || normalized.contains("cpu") || normalized.contains("memory") {
            return "cpu"
        }
        if normalized.contains("append") {
            return "text.badge.plus"
        }
        if normalized.contains("delete") || normalized.contains("remove") || normalized.contains("trash") {
            return "trash"
        }
        if normalized.contains("create") || normalized.contains("make") || normalized.contains("write") {
            return "doc.badge.plus"
        }
        if normalized.contains("read") || normalized.contains("view") || normalized.contains("inspect") {
            return "doc.text.magnifyingglass"
        }
        if normalized.contains("search") || normalized.contains("find") {
            return "magnifyingglass"
        }
        if normalized.contains("skill") {
            return "sparkles"
        }
        if normalized.contains("command") || normalized.contains("terminal") || normalized.contains("shell") || normalized.contains("bash") {
            return "terminal.fill"
        }
        if normalized.contains("symbol") || normalized.contains("code") || normalized.contains("syntax") {
            return "curlybraces"
        }
        if normalized.contains("audit") || normalized.contains("security") || normalized.contains("verify") || normalized.contains("validate") {
            return "checkmark.shield.fill"
        }
        if normalized.contains("image") || normalized.contains("photo") || normalized.contains("draw") {
            return "photo"
        }
        if normalized.contains("web") || normalized.contains("url") || normalized.contains("http") || normalized.contains("network") {
            return "globe"
        }
        if normalized.contains("model") || normalized.contains("catalog") {
            return "square.stack.3d.up.fill"
        }
        return "wrench.and.screwdriver.fill"
    }

    /// Formats a raw parameter key cleanly (e.g. "file_path" -> "File Path", "query" -> "Query").
    public nonisolated static func formatArgumentKey(_ rawKey: String) -> String {
        let tokens = tokenize(rawKey)
        guard !tokens.isEmpty else { return rawKey }
        return formatNouns(tokens)
    }

    // MARK: - Private Helpers

    private nonisolated static func assemble(verb: String, participle: String, nouns: [String]) -> String {
        guard !nouns.isEmpty else { return participle }
        let nounPhrase = formatNouns(nouns)
        if verb == "append" {
            if nounPhrase.lowercased().hasPrefix("to ") {
                return "\(participle) \(nounPhrase)"
            } else {
                return "\(participle) to \(nounPhrase)"
            }
        }
        return "\(participle) \(nounPhrase)"
    }

    private nonisolated static func participle(for word: String) -> String? {
        let lower = word.lowercased()
        if let match = verbParticiples[lower] {
            return match
        }
        if lower.count >= 4 && lower.hasSuffix("ing") {
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }
        return nil
    }

    private nonisolated static func pastTense(for word: String) -> String? {
        let lower = word.lowercased()
        if let match = verbPastTense[lower] {
            return match
        }
        if lower.count >= 4 && lower.hasSuffix("ed") {
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }
        return nil
    }

    private nonisolated static func tokenize(_ input: String) -> [String] {
        var cleaned = input
        for prefix in ["tool_", "assist_tool_", "fn_", "agent_"] {
            if cleaned.lowercased().hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count))
                break
            }
        }
        let separated = cleaned
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: ":", with: " ")

        var tokens: [String] = []
        for part in separated.split(separator: " ") {
            tokens.append(contentsOf: splitCamelCase(String(part)))
        }
        return tokens.filter { !$0.isEmpty }
    }

    private nonisolated static func splitCamelCase(_ string: String) -> [String] {
        var words: [String] = []
        var currentWord = ""
        let chars = Array(string)

        for i in 0..<chars.count {
            let char = chars[i]
            if char.isUppercase {
                let prevIsLower = (i > 0) && chars[i - 1].isLowercase
                let nextIsLower = (i + 1 < chars.count) && chars[i + 1].isLowercase
                let prevIsUpper = (i > 0) && chars[i - 1].isUppercase

                if prevIsLower || (prevIsUpper && nextIsLower) {
                    if !currentWord.isEmpty {
                        words.append(currentWord)
                        currentWord = ""
                    }
                }
            }
            currentWord.append(char)
        }
        if !currentWord.isEmpty {
            words.append(currentWord)
        }
        return words
    }

    private nonisolated static func formatNouns(_ tokens: [String]) -> String {
        let specialAcronyms: Set<String> = ["ui", "api", "url", "id", "os", "llm", "mlx", "ram", "cpu", "gpu"]
        let minorWords: Set<String> = ["and", "or", "in", "on", "at", "by", "for", "with", "of"]

        return tokens.enumerated().map { index, token in
            let lower = token.lowercased()
            if specialAcronyms.contains(lower) {
                return lower.uppercased()
            }
            if lower == "mac" {
                return "Mac"
            }
            if index > 0 && minorWords.contains(lower) {
                return lower
            }
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }.joined(separator: " ")
    }
}
