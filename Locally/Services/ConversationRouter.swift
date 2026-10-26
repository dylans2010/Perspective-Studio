import Foundation

/// What one user turn actually needs from the pipeline.
///
/// This is the lightweight routing stage the conversation pipeline was
/// missing: before it existed, *every* message — including "hello" — was
/// sent through full index retrieval (tool schemas, skill excerpts, asset
/// summaries) and, in Agent mode, a ten-turn autonomous tool loop whose
/// system prompt demanded a "comprehensive, well-structured Markdown
/// response". A local model handed a greeting plus a capability catalog
/// and an instruction to be comprehensive does the predictable thing: it
/// recites the catalog as dozens of bullet points.
///
/// The router is deliberately conservative and deterministic:
/// - `.conversational` is returned ONLY for whole-message matches against
///   a small set of unambiguous social patterns (greetings, thanks,
///   acknowledgements, farewells, "how are you"). Any additional clause,
///   question, or task signal disqualifies the match. It never fires for
///   a message that merely *starts* with a greeting ("hello, can you read
///   this file" is a task).
/// - `.task` requires a strong action signal: an imperative/task verb, a
///   file/code/system reference, or an explicit tool-ish request.
/// - Everything else is `.direct`: answer the question or continue the
///   discussion directly, with only lexically relevant retrieved context
///   and no tool schemas — but no fabricated answer either; the model
///   still produces the response, and in Agent mode a direct turn that
///   turns out to contain a genuine tool call escalates to the full loop
///   (see `AntigravityAgentHarness`).
///
/// The router never fabricates a final answer and never bypasses the
/// core system instructions, custom user instructions, or safety rules:
/// those ride on every route. It only decides how much machinery —
/// retrieval, tools, looping — a turn is offered.
public enum ConversationIntent: String, Sendable, Equatable, CaseIterable {
    case conversational
    case direct
    case task

    /// Whether turns of this intent may be offered tool schemas / a tool loop.
    public var allowsToolMachinery: Bool { self == .task }
}

public nonisolated enum ConversationRouter {

    // MARK: - Public API

    public static func intent(for message: String) -> ConversationIntent {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .direct }
        // Any task signal routes directly to .task for tool access
        if hasTaskSignal(trimmed) { return .task }
        // Identity / purpose / capability questions are `.direct`:
        // they need authoritative identity instructions retrieved and a real
        // (brief) answer without conversational dismissal or starting tool loops.
        if ContextIndexManager.isIdentityQuery(trimmed) { return .direct }
        // Strict whole-message small talk / greetings return .conversational
        if matchesConversationalPattern(trimmed) { return .conversational }
        return .direct
    }

    /// Convenience for call sites that only need the conversational gate.
    public static func isConversational(_ message: String) -> Bool {
        intent(for: message) == .conversational
    }

    // MARK: - Conversational patterns (whole-message, conservative)

    /// Normalized form for pattern matching: lowercased, punctuation
    /// stripped, whitespace collapsed. Attachments markers (📎/📹/🖼 lines
    /// that `ChatViewModel` prepends to the persisted user message) are
    /// removed first — a message with an attachment is never a bare
    /// greeting.
    static func normalized(_ message: String) -> String {
        var text = message
        // Drop attachment marker lines the view model prepends.
        let lines = text.components(separatedBy: .newlines).filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !(t.hasPrefix("📎") || t.hasPrefix("📹") || t.hasPrefix("🖼") || t.hasPrefix("⚠️"))
        }
        text = lines.joined(separator: " ")
        let lowered = text.lowercased()
        let scalars = lowered.unicodeScalars.filter { scalar in
            CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) || scalar.value == 32 || scalar.value == 39
        }
        let collapsed = String(String.UnicodeScalarView(scalars))
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed
    }

    static func matchesConversationalPattern(_ message: String) -> Bool {
        let text = normalized(message)
        guard !text.isEmpty, text.count <= 60 else { return false }
        // A question about something, or any clause beyond the social
        // pattern itself, is not a bare conversational turn.
        if text.contains(" what ") || text.contains(" why ") || text.contains(" when ")
            || text.contains(" where ") || text.contains(" which ") { return false }

        if greetingPatterns.contains(text) { return true }
        if thanksPatterns.contains(text) { return true }
        if acknowledgementPatterns.contains(text) { return true }
        if farewellPatterns.contains(text) { return true }
        if smallTalkPatterns.contains(text) { return true }

        // Greeting + a social tail only ("hello there", "hey how are you",
        // "good morning everyone"). The tail set is closed: anything else
        // after the greeting makes it a real message.
        for greeting in greetingHeads {
            if text == greeting { return true }
            if text.hasPrefix(greeting + " ") {
                let tail = String(text.dropFirst(greeting.count + 1))
                if socialTails.contains(tail) { return true }
            }
        }
        return false
    }

    private static let greetingHeads: [String] = [
        "hello", "hi", "hey", "hiya", "howdy", "yo", "greetings",
        "good morning", "good afternoon", "good evening"
    ]

    private static let socialTails: Set<String> = [
        "there", "everyone", "everybody", "all", "again", "friend", "friends",
        "how are you", "how's it going", "hows it going", "how is it going",
        "how are you doing", "how do you do", "what's up", "whats up"
    ]

    private static let greetingPatterns: Set<String> = [
        "hello there", "hi there", "hey there", "hello again", "hi again",
        "morning", "good morning everyone", "hello everyone", "hey everyone",
        "hello how are you", "hi how are you", "hey how are you"
    ]

    private static let smallTalkPatterns: Set<String> = [
        "how are you", "how are you doing", "how's it going", "hows it going",
        "how is it going", "what's up", "whats up", "how do you do",
        "are you there", "are you awake", "you there", "who are you",
        "what are you" // identity small-talk; a longer "what are you …" won't match whole-message
    ]

    private static let thanksPatterns: Set<String> = [
        "thanks", "thank you", "thanks a lot", "thank you so much",
        "thanks so much", "thx", "ty", "many thanks", "perfect thanks",
        "great thanks", "awesome thanks", "thank you very much"
    ]

    private static let acknowledgementPatterns: Set<String> = [
        "ok", "okay", "cool", "nice", "great", "perfect", "awesome",
        "sounds good", "got it", "understood", "makes sense", "good",
        "excellent", "wonderful", "brilliant", "sweet", "neat", "yes",
        "yep", "yeah", "sure", "alright", "fair enough", "no worries",
        "that works", "works for me", "looks good",
        // Bare interjections: thinking noises with no question and no
        // task. Classifying "hmm" as a general direct question gave it
        // the full retrieval treatment; as conversation it gets a
        // brief, natural reply that invites the actual question.
        "hmm", "hm", "huh", "mm", "mmm", "hmm okay", "hmm ok"
    ]

    private static let farewellPatterns: Set<String> = [
        "bye", "goodbye", "bye bye", "see you", "see you later",
        "see you soon", "good night", "goodnight", "talk later",
        "that's all", "thats all", "nothing else", "i'm good", "im good",
        "all good", "we're done", "were done", "done for now"
    ]

    // MARK: - Task signals

    /// Action continuation phrases that indicate permission or instruction to proceed with prior tasks.
    private static let actionContinuationPhrases: [String] = [
        "do it", "do that", "do it then", "proceed", "go ahead", "execute it"
    ]

    /// Target file extensions recognized as work objects.
    private static let targetFileExtensions: Set<String> = [
        "swift", "py", "js", "ts", "json", "md", "txt", "html", "css",
        "yml", "yaml", "xml", "c", "cpp", "h", "m", "rs", "go", "sh", "rb"
    ]

    /// Polite imperative prefixes that, when followed by a task verb, indicate a task turn.
    private static let politeImperativePrefixes: [[String]] = [
        ["can", "you"],
        ["could", "you"],
        ["please"],
        ["would", "you"],
        ["will", "you"],
        ["help", "me"],
        ["i", "need", "you", "to"],
        ["i", "want", "you", "to"]
    ]

    /// Strong signals that a turn genuinely needs tools / inspection /
    /// execution. Deliberately verb- and object-based, not a keyword dump:
    /// a bare topic phrase ("banana smoothie recipe") is `.direct`.
    nonisolated static func hasTaskSignal(_ message: String) -> Bool {
        let text = normalized(message)
        guard !text.isEmpty else { return false }
        let words = text.components(separatedBy: " ")
        let wordSet = Set(words)

        // 1. Action continuation phrases ("do it", "do that", "proceed", "go ahead", etc.)
        if matchesActionContinuation(text) { return true }

        // Imperative / task verbs anywhere in the message. These are
        // verbs whose presence means the user asked for work to be done,
        // not for a fact to be stated.
        let taskVerbs: Set<String> = [
            "fix", "debug", "build", "compile", "implement", "refactor",
            "create", "write", "edit", "update", "delete", "remove",
            "rename", "move", "copy", "download", "upload", "install",
            "uninstall", "run", "execute", "launch", "open", "read",
            "inspect", "audit", "review", "search", "find", "list",
            "show", "check", "test", "deploy", "commit", "push", "merge",
            "generate", "convert", "export", "import", "calculate",
            "compute", "analyze", "analyse", "summarize", "summarise",
            "screenshot", "click", "type", "browse", "fetch", "scan",
            "do", "investigate", "examine", "explore", "diagnose"
        ]

        // 2. Polite imperative prefix followed by a task verb:
        // "can you", "could you", "please", "would you", "will you",
        // "help me", "i need you to", "i want you to"
        if hasPoliteImperative(words: words, taskVerbs: taskVerbs) {
            return true
        }

        // Object-ish nouns that turn a question into an inspection task
        // when combined with a question/interrogative frame.
        let workObjects: Set<String> = [
            "file", "files", "folder", "directory", "project", "code",
            "codebase", "repo", "repository", "function", "class", "bug",
            "error", "crash", "screenshot", "screen", "app", "window",
            "server", "database", "spreadsheet", "document", "email"
        ]
        let hasVerb = !wordSet.isDisjoint(with: taskVerbs)
        let hasFileOrPath = hasFileOrPathReference(message, normalizedWords: words)
        let hasWorkObject = !wordSet.isDisjoint(with: workObjects) || hasFileOrPath

        // Imperative form: the message *starts* with a task verb
        // ("fix the layout", "search for memory leaks", "check my email").
        if let first = words.first, taskVerbs.contains(first) { return true }
        // Verb + work object anywhere: "can you search the project for…",
        // "please read the file and…". A verb alone is not enough —
        // "how do I write a haiku" is a generation request the model
        // answers directly, not a tool task.
        if hasVerb && hasWorkObject { return true }
        if hasVerb && text.contains("please") { return true }
        // "what's in this folder", "how much memory does my mac have" —
        // questions that can only be answered by inspecting this machine.
        if hasWorkObject && (text.contains("my ") || text.contains("this ") || text.contains("current")) {
            return true
        }
        if text.contains("my mac") || text.contains("this mac") || text.contains("on my computer") {
            return true
        }
        return false
    }

    private static func matchesActionContinuation(_ text: String) -> Bool {
        let padded = " " + text + " "
        for phrase in actionContinuationPhrases {
            if padded.contains(" " + phrase + " ") {
                return true
            }
        }
        return false
    }

    private static func hasPoliteImperative(words: [String], taskVerbs: Set<String>) -> Bool {
        guard !words.isEmpty else { return false }
        for prefix in politeImperativePrefixes {
            let pLen = prefix.count
            guard words.count > pLen else { continue }
            for i in 0...(words.count - pLen) {
                if Array(words[i..<(i + pLen)]) == prefix {
                    let trailingWords = words[(i + pLen)...]
                    if trailingWords.contains(where: { taskVerbs.contains($0) }) {
                        return true
                    }
                }
            }
        }
        return false
    }

    private static func hasFileOrPathReference(_ message: String, normalizedWords: [String]) -> Bool {
        // 1. Raw message token detection (preserves . and /)
        let rawTokens = message.components(separatedBy: .whitespacesAndNewlines)
        for token in rawTokens {
            let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}><\"'!?.,;:"))
            guard !trimmed.isEmpty else { continue }

            let tokenWithoutLineNumber = trimmed.components(separatedBy: ":").first ?? trimmed

            if let dotIndex = tokenWithoutLineNumber.lastIndex(of: ".") {
                let ext = String(tokenWithoutLineNumber[tokenWithoutLineNumber.index(after: dotIndex)...]).lowercased()
                if targetFileExtensions.contains(ext) {
                    return true
                }
            }

            if trimmed.contains("/") {
                let lower = trimmed.lowercased()
                if !lower.hasPrefix("http://") && !lower.hasPrefix("https://")
                    && lower != "and/or" && lower != "either/or" && lower != "w/o" && lower != "n/a" {
                    let isDate = trimmed.allSatisfy { $0.isNumber || $0 == "/" }
                    if !isDate {
                        return true
                    }
                }
            }
        }

        // 2. Normalized words detection (handles stripped periods / collapsed tokens)
        let unambiguousSuffixExtensions = ["swift", "json", "yaml", "yml", "html", "css", "cpp", "txt", "xml"]
        for word in normalizedWords {
            for ext in unambiguousSuffixExtensions {
                if word.hasSuffix(ext) && word.count > ext.count {
                    return true
                }
            }
        }

        for i in 1..<normalizedWords.count {
            let current = normalizedWords[i]
            if targetFileExtensions.contains(current) {
                let prev = normalizedWords[i - 1]
                let nonIdentifierWords: Set<String> = [
                    "a", "an", "the", "in", "on", "at", "to", "for", "of", "with", "by", "from",
                    "and", "or", "is", "are", "was", "were", "be", "been", "write", "learn", "teach"
                ]
                if !nonIdentifierWords.contains(prev) && prev.count >= 2 {
                    return true
                }
            }
        }

        return false
    }
}
