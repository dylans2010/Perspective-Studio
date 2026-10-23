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

    nonisolated(unsafe) private static let tagPairs: [(open: String, close: String)] = [
        ("<thinking>", "</thinking>"),
        ("<think>", "</think>")
    ]

    nonisolated static func parse(_ raw: String) -> ParsedContent {
        var result = ParsedContent()
        var remaining = normalizeHarmonyChannels(raw)[...]

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

            // Unmatched closing tag: several reasoning templates (DeepSeek
            // R1, QwQ, …) pre-fill the opening <think> tag into the prompt,
            // so the model's output STARTS mid-reasoning and the first tag
            // it ever emits is the closing one. Everything before that
            // close is reasoning, not answer — without this case the whole
            // chain-of-thought renders as the reply.
            var earliestClose: Range<Substring.Index>?
            for pair in tagPairs {
                if let range = remaining.range(of: pair.close, options: .caseInsensitive) {
                    if earliestClose == nil || range.lowerBound < earliestClose!.lowerBound {
                        earliestClose = range
                    }
                }
            }
            if let close = earliestClose, earliest == nil || close.lowerBound < earliest!.range.lowerBound {
                let block = remaining[..<close.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !block.isEmpty {
                    result.thinkingBlocks.append(block)
                }
                remaining = remaining[close.upperBound...]
                continue
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

    /// Harmony-format models (gpt-oss) delimit reasoning with channel
    /// markers instead of tags: `<|channel|>analysis<|channel|>` opens the
    /// reasoning channel and `<|channel|>final<|channel|>` closes it into
    /// the answer. Translate those markers to the tag spelling the rest of
    /// the parser (and the history stripper) already understands, and drop
    /// the format's bare `<|end|>` message terminators.
    nonisolated static func normalizeHarmonyChannels(_ raw: String) -> String {
        guard raw.contains("<|channel|>") else { return raw }
        var normalized = raw
        normalized = normalized.replacing("<|channel|>analysis<|channel|>", with: "<thinking>")
        normalized = normalized.replacing("<|channel|>final<|channel|>", with: "</thinking>")
        normalized = normalized.replacing("<|end|>", with: "")
        return normalized
    }

    /// The user-visible part of a response (thinking blocks removed).
    nonisolated static func visibleContent(of raw: String) -> String {
        parse(raw).answer
    }

    /// True when `raw` contains any thinking tag, open or closed.
    nonisolated static func containsThinkingTags(_ raw: String) -> Bool {
        tagPairs.contains { pair in
            raw.range(of: pair.open, options: .caseInsensitive) != nil
        }
    }
}
