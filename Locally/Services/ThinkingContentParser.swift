import Foundation

/// Splits a model response into its private reasoning and its final answer.
///
/// Reasoning models (and Locally's own thinking instruction, see
/// `ModelContextBuilder`) wrap chain-of-thought in `<thinking>…</thinking>`
/// tags — some model families use the shorter `<think>…</think>` spelling.
/// Everything inside those tags is what the model *thought*; everything
/// outside is what it *said*. The chat UI renders the two separately
/// (`ThinkingModelUI`) and the inference layer strips thinking blocks from
/// assistant history before re-sending them, so reasoning tokens don't eat
/// the context window on later turns.
enum ThinkingContentParser {

    struct ParsedContent: Equatable, Sendable {
        /// Every thinking block, in order, trimmed of surrounding whitespace.
        var thinkingBlocks: [String] = []
        /// The response with all thinking blocks removed.
        var answer: String = ""
        /// True while the final thinking block has no closing tag yet —
        /// i.e. the model is still streaming its reasoning.
        var isThinkingOpen: Bool = false

        var hasThinking: Bool { !thinkingBlocks.isEmpty }

        /// All thinking blocks joined for display.
        var thinkingText: String { thinkingBlocks.joined(separator: "\n\n") }
    }

    private static let tagPairs: [(open: String, close: String)] = [
        ("<thinking>", "</thinking>"),
        ("<think>", "</think>")
    ]

    static func parse(_ raw: String) -> ParsedContent {
        var result = ParsedContent()
        var remaining = raw[raw.startIndex...]

        while !remaining.isEmpty {
            // Find the earliest opening tag of either spelling.
            var earliest: (range: Range<Substring.Index>, close: String)?
            for pair in tagPairs {
                if let range = remaining.range(of: pair.open, options: .caseInsensitive) {
                    if earliest == nil || range.lowerBound < earliest!.range.lowerBound {
                        earliest = (range, pair.close)
                    }
                }
            }

            guard let opening = earliest else {
                result.answer.append(contentsOf: remaining)
                break
            }

            result.answer.append(contentsOf: remaining[..<opening.range.lowerBound])
            let afterOpen = remaining[opening.range.upperBound...]

            if let closeRange = afterOpen.range(of: opening.close, options: .caseInsensitive) {
                let block = afterOpen[..<closeRange.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !block.isEmpty {
                    result.thinkingBlocks.append(block)
                }
                remaining = afterOpen[closeRange.upperBound...]
            } else {
                // Unclosed tag: the model is still thinking (streaming), or
                // it never closed the block. Either way the rest is thought,
                // not answer.
                let block = afterOpen.trimmingCharacters(in: .whitespacesAndNewlines)
                if !block.isEmpty {
                    result.thinkingBlocks.append(block)
                }
                result.isThinkingOpen = true
                remaining = remaining[remaining.endIndex...]
            }
        }

        result.answer = result.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    /// The user-visible part of a response (thinking blocks removed).
    static func visibleContent(of raw: String) -> String {
        parse(raw).answer
    }

    /// True when `raw` contains any thinking tag, open or closed.
    static func containsThinkingTags(_ raw: String) -> Bool {
        tagPairs.contains { pair in
            raw.range(of: pair.open, options: .caseInsensitive) != nil
        }
    }
}
