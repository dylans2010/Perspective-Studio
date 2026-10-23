import Foundation

/// Removes raw tool-invocation plumbing from model text before it is ever
/// shown to the user.
///
/// Agent-mode models speak a text protocol (`TOOL_CALL {"tool": …}` or a
/// bare JSON object) that the runtime parses and executes. That protocol is
/// private plumbing: when a model echoes it into its visible reply — or when
/// a turn's tokens are streamed before the runtime has classified the turn —
/// the user sees raw JSON and internal tool identifiers in the chat bubble
/// (see the 2026-10-23 screenshots: `{"tool": "computer_get_permissions", …}`
/// rendered as the assistant's message). The sanctioned place for tool
/// activity is the tool-card UI (`ToolCallView`), never the message text.
///
/// This sanitizer is applied at every layer that can reach the screen:
/// the harness sanitizes its final answer, `ChatViewModel` sanitizes
/// streamed and persisted content, and the message row sanitizes again at
/// render time, so even messages saved by older builds display cleanly.
///
/// Rules:
/// - Complete and partial `TOOL_CALL …` payloads are removed.
/// - Bare JSON objects whose `tool` value is a *known* tool id are removed
///   (a JSON example about some other "tool" is the user's content, not an
///   invocation, and is left alone).
/// - `<tool_call>…</tool_call>`-style wrappers are removed.
/// - Raw tool identifiers are never left in prose: `file_append: Append to
///   File` becomes `Append to File`, and a bare or backticked snake_case
///   tool id is replaced by its human action name (`ToolNameFormatter`).
public enum ToolInvocationSanitizer {

    // MARK: - Public API

    /// True when `text` contains tool-invocation syntax (complete or partial).
    public nonisolated static func containsInvocation(_ text: String, knownToolIDs: Set<String>) -> Bool {
        if text.range(of: "TOOL_CALL") != nil { return true }
        if text.range(of: "<tool_call", options: .caseInsensitive) != nil { return true }
        if text.range(of: "<function_call", options: .caseInsensitive) != nil { return true }
        return stripInvocations(from: text, knownToolIDs: knownToolIDs) != text
    }

    /// The text exactly as it may be shown to the user: invocations stripped,
    /// raw tool identifiers redacted, leftover blank space collapsed.
    public nonisolated static func displayText(for text: String, knownToolIDs: Set<String>) -> String {
        let stripped = stripInvocations(from: text, knownToolIDs: knownToolIDs)
        let markersRemoved = stripInternalMarkers(from: stripped)
        let redacted = redactToolIdentifiers(in: markersRemoved, knownToolIDs: knownToolIDs)
        // Stripping an invocation that sat inside a fenced block leaves
        // an EMPTY fence behind (```json … ``` with nothing between the
        // fences) — the exact "one comment followed by several empty
        // code blocks" artifact in the Agent screenshots. Empty fences
        // carry no content and are removed; fences with real code are
        // untouched.
        let fencesCleaned = stripEmptyCodeFences(in: redacted)
        return collapseBlankSpace(fencesCleaned)
    }

    /// Removes fenced code blocks that contain nothing but whitespace
    /// (an optional language tag rides on the opening fence line itself).
    /// A block with any non-whitespace content is preserved verbatim,
    /// as is an unterminated fence that has content. An unterminated
    /// fence with no content at all is dropped — it can only be the
    /// husk of a stripped invocation.
    public nonisolated static func stripEmptyCodeFences(in text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var kept: [String] = []
        var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("```") else {
                kept.append(lines[index])
                index += 1
                continue
            }
            // Opening fence: find its closing fence.
            var close = index + 1
            while close < lines.count, !lines[close].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                close += 1
            }
            if close >= lines.count {
                // Unterminated: keep it only if real content follows.
                let tail = lines[(index + 1)...]
                if tail.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    kept.append(contentsOf: lines[index...])
                }
                break
            }
            let body = lines[(index + 1)..<close]
            if body.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                // Empty block: drop opening fence, body, and closing fence.
                index = close + 1
            } else {
                kept.append(contentsOf: lines[index...close])
                index = close + 1
            }
        }
        return kept.joined(separator: "\n")
    }

    // MARK: - Internal loop markers (defense in depth)

    /// Removes THIS app's own internal loop-control markers if a model
    /// echoes them. This is deliberately a closed list of exact internal
    /// strings the runtime itself generated — not a general bracket or
    /// tag stripper (legitimate bracketed text and Markdown survive).
    ///
    /// Origin fix, not just filtering: the loop no longer writes the
    /// "withheld" draft marker into the model-visible history at all
    /// (see `AntigravityAgentHarness`); these removals exist so messages
    /// persisted by older builds, and any model paraphrase of the old
    /// history, still render cleanly.
    public nonisolated static func stripInternalMarkers(from text: String) -> String {
        var result = text

        // Bracketed loop markers: "[Answer withheld]", "[Draft answer
        // withheld — no tools used yet]", "[Used a tool: …]". Remove the
        // whole bracketed segment for these known prefixes only.
        for prefix in ["[Answer withheld", "[Draft answer withheld", "[Used a tool:"] {
            while let start = result.range(of: prefix) {
                if let end = result.range(of: "]", range: start.upperBound..<result.endIndex) {
                    result.removeSubrange(start.lowerBound..<end.upperBound)
                } else {
                    result = String(result[..<start.lowerBound])
                    break
                }
            }
        }

        // Instruction-echo lines: the model paraphrasing its own prompt
        // back ("Response Style: Write your final answer below the
        // tags."). Origin fix: the harness prompt no longer presents a
        // "Response Style:" block telling the model where to write its
        // final answer; this drops the known echoed line form if a
        // model still produces it.
        let lines = result.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lowered = trimmed.lowercased()
            let isEcho = (lowered.hasPrefix("response style:") || lowered.hasPrefix("response style —"))
                && (lowered.contains("final answer") || lowered.contains("below the tags") || lowered.contains("after the closing tag"))
            return !isEcho
        }
        result = lines.joined(separator: "\n")
        return result
    }

    /// Removes tool-invocation payloads, leaving the surrounding prose.
    public nonisolated static func stripInvocations(from text: String, knownToolIDs: Set<String>) -> String {
        var result = text

        // 1. XML-style wrappers, closed or still streaming (unclosed → to end).
        for tag in ["tool_call", "tool_calls", "function_call", "function_calls"] {
            result = stripTaggedBlocks(in: result, tag: tag)
        }

        // 2. TOOL_CALL marker + its JSON payload (balanced, or partial to end).
        result = stripToolCallMarkers(in: result)

        // 3. Fenced ```json blocks that contain a tool invocation.
        result = stripFencedToolBlocks(in: result, knownToolIDs: knownToolIDs)

        // 4. Bare JSON objects that are tool invocations.
        result = stripBareToolJSON(in: result, knownToolIDs: knownToolIDs)

        // 5. A trailing unterminated fragment that has begun a tool object
        //    (mid-stream `{"tool": "…` with no closing brace yet).
        result = stripPartialToolFragment(in: result)

        return result
    }

    /// Replaces raw tool identifiers in prose with human action names and
    /// removes `raw_id: Human Label` prefixes, keeping the human label.
    public nonisolated static func redactToolIdentifiers(in text: String, knownToolIDs: Set<String>) -> String {
        guard !knownToolIDs.isEmpty, !text.isEmpty else { return text }
        var result = text

        // Longest first so overlapping ids resolve to the most specific one.
        for toolID in knownToolIDs.sorted(by: { $0.count > $1.count }) {
            let humanName = ToolNameFormatter.format(toolID)

            // `file_append: Append to File` / `file_append — Append to File`:
            // drop the `id:` / `id —` prefix, keep the model's human label.
            for separator in [":", "—", "–"] {
                let labeled = "\(toolID) \(separator) "
                result = result.replacing(labeled, with: "")
                let labeledTight = "\(toolID)\(separator) "
                result = result.replacing(labeledTight, with: "")
            }

            // Backticked id → human name without backticks.
            result = result.replacing("`\(toolID)`", with: humanName)

            // Bare snake_case ids (underscore is the tell — ordinary prose
            // words and single-word ids like `calculator` are left alone).
            if toolID.contains("_") || toolID.contains("-") {
                result = replaceWholeToken(toolID, in: result, with: humanName)
            }
        }
        return result
    }

    // MARK: - Tagged blocks

    private nonisolated static func stripTaggedBlocks(in text: String, tag: String) -> String {
        var result = text
        let open = "<\(tag)"
        let close = "</\(tag)>"
        while let openRange = result.range(of: open, options: .caseInsensitive) {
            // The opening tag may carry attributes; it ends at the first '>'.
            guard let tagEnd = result.range(of: ">", range: openRange.upperBound..<result.endIndex) else {
                // No complete opening tag: everything from here is plumbing.
                return String(result[..<openRange.lowerBound])
            }
            if let closeRange = result.range(of: close, options: .caseInsensitive, range: tagEnd.upperBound..<result.endIndex) {
                result.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
            } else {
                // Unclosed (still streaming or malformed): cut to the end.
                return String(result[..<openRange.lowerBound])
            }
        }
        return result
    }

    // MARK: - TOOL_CALL markers

    private nonisolated static func stripToolCallMarkers(in text: String) -> String {
        var result = text
        while let marker = result.range(of: "TOOL_CALL") {
            let after = result[marker.upperBound...]
            let trimmed = after.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.first == "{" {
                let slice = result[trimmed.startIndex...]
                if let jsonRange = balancedJSONRange(in: slice) {
                    result.removeSubrange(marker.lowerBound..<jsonRange.upperBound)
                } else {
                    // Partial payload still arriving: hide everything from
                    // the marker onward rather than leaking fragments.
                    return String(result[..<marker.lowerBound])
                }
            } else if trimmed.isEmpty {
                return String(result[..<marker.lowerBound])
            } else {
                // Marker with no payload (model wrote the word only): drop
                // just the marker token.
                result.removeSubrange(marker)
            }
        }
        return result
    }

    // MARK: - Fenced JSON blocks

    private nonisolated static func stripFencedToolBlocks(in text: String, knownToolIDs: Set<String>) -> String {
        var result = text
        var searchStart = result.startIndex
        while let fence = result.range(of: "```", range: searchStart..<result.endIndex) {
            let contentStart = fence.upperBound
            guard let closeFence = result.range(of: "```", range: contentStart..<result.endIndex) else {
                // Unterminated fence still streaming: hide it if what has
                // arrived so far already looks like a tool invocation.
                let tail = result[contentStart...]
                if isToolInvocationJSON(String(tail), knownToolIDs: knownToolIDs) || tail.contains("\"tool\"") {
                    return String(result[..<fence.lowerBound])
                }
                return result
            }
            let block = result[contentStart..<closeFence.lowerBound]
            // Skip a language tag line (```json) before judging the content.
            var payload = block
            if let newline = block.firstIndex(of: "\n") {
                let firstLine = block[..<newline].trimmingCharacters(in: .whitespaces)
                if firstLine.isEmpty || firstLine.allSatisfy({ $0.isLetter }) {
                    payload = block[block.index(after: newline)...]
                }
            }
            if isToolInvocationJSON(String(payload), knownToolIDs: knownToolIDs) {
                result.removeSubrange(fence.lowerBound..<closeFence.upperBound)
                searchStart = result.startIndex
            } else {
                searchStart = closeFence.upperBound
            }
        }
        return result
    }

    // MARK: - Bare JSON objects

    private nonisolated static func stripBareToolJSON(in text: String, knownToolIDs: Set<String>) -> String {
        var result = text
        var cursor = result.startIndex
        while let brace = result.range(of: "{", range: cursor..<result.endIndex) {
            let slice = result[brace.lowerBound...]
            guard let jsonRange = balancedJSONRange(in: slice) else {
                // Unbalanced from here on (streaming): handled by the
                // partial-fragment pass.
                break
            }
            let candidate = String(result[brace.lowerBound..<jsonRange.upperBound])
            if isToolInvocationJSON(candidate, knownToolIDs: knownToolIDs) {
                result.removeSubrange(brace.lowerBound..<jsonRange.upperBound)
                cursor = result.startIndex
            } else {
                cursor = jsonRange.upperBound
            }
        }
        return result
    }

    private nonisolated static func stripPartialToolFragment(in text: String) -> String {
        // Find the last '{' whose remainder never closes and which already
        // names a tool — that is an invocation caught mid-stream.
        var searchFrom = text.startIndex
        var cutIndex: String.Index?
        while let brace = text.range(of: "{", range: searchFrom..<text.endIndex) {
            let slice = text[brace.lowerBound...]
            if balancedJSONRange(in: slice) == nil, slice.contains("\"tool\"") {
                cutIndex = brace.lowerBound
                break
            }
            searchFrom = text.index(after: brace.lowerBound)
        }
        if let cutIndex {
            return String(text[..<cutIndex])
        }
        return text
    }

    // MARK: - JSON helpers

    /// Whether a JSON string is a tool invocation: an object with a `tool`
    /// (or `name`/`function`) string that is a known tool id, or — when the
    /// caller supplied no known ids — any such object that also carries an
    /// arguments payload.
    private nonisolated static func isToolInvocationJSON(_ json: String, knownToolIDs: Set<String>) -> Bool {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        guard let toolValue = (object["tool"] ?? object["name"] ?? object["function"]) as? String,
              !toolValue.isEmpty else {
            return false
        }
        if knownToolIDs.contains(toolValue) { return true }
        if knownToolIDs.isEmpty {
            return object["arguments"] != nil || object["parameters"] != nil || object["input"] != nil
        }
        return false
    }

    /// The range of the balanced `{…}` object starting at the first
    /// character of `text` (which must be `{`), string/escape aware.
    private nonisolated static func balancedJSONRange(in text: Substring) -> Range<Substring.Index>? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if escaped {
                escaped = false
            } else if char == "\\" && inString {
                escaped = true
            } else if char == "\"" {
                inString.toggle()
            } else if !inString {
                if char == "{" {
                    depth += 1
                } else if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        return text.startIndex..<text.index(after: index)
                    }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    // MARK: - Text helpers

    /// Replaces occurrences of `token` that are not glued to other
    /// identifier characters (letters, digits, `_`, `-`, `.`, `/`).
    private nonisolated static func replaceWholeToken(_ token: String, in text: String, with replacement: String) -> String {
        guard text.contains(token) else { return text }
        var result = ""
        var remaining = text[...]
        while let range = remaining.range(of: token) {
            let before = remaining[..<range.lowerBound]
            let after = remaining[range.upperBound...]
            let beforeOK = before.last.map { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" && $0 != "." && $0 != "/" } ?? true
            let afterOK = after.first.map { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" } ?? true
            result += before
            result += (beforeOK && afterOK) ? replacement : token
            remaining = after
        }
        result += remaining
        return result
    }

    private nonisolated static func collapseBlankSpace(_ text: String) -> String {
        var result = text
        while result.contains("\n\n\n") {
            result = result.replacing("\n\n\n", with: "\n\n")
        }
        // Drop spaces left dangling at line ends by removed payloads.
        result = result
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) == "" ? "" : $0 }
            .joined(separator: "\n")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
