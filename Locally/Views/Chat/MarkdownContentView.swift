import SwiftUI
import AppKit

/// Renders rich Markdown content in chat messages:
/// - Unwraps accidental outer ````markdown ... ```` code blocks commonly emitted by LLMs.
/// - Parses real headings (`#` to `####`), ordered lists, unordered lists, blockquotes, tables, dividers, and code blocks.
/// - Inlines bold, italic, code, and links through Foundation's `AttributedString` markdown parser.
struct MarkdownContentView: View {
    let content: String

    private var parsedBlocks: [IdentifiableMarkdownBlock] {
        let unwrapped = Self.unwrapOuterMarkdownFence(content)
        var items: [IdentifiableMarkdownBlock] = []

        let parts = unwrapped.components(separatedBy: "```")
        for (index, part) in parts.enumerated() {
            if index % 2 == 1 {
                // Fenced code block: first line may specify the language tag
                var lines = part.components(separatedBy: "\n")
                var language: String? = nil
                if let first = lines.first?.trimmingCharacters(in: .whitespaces),
                   !first.contains(" "),
                   first.count <= 25,
                   !first.isEmpty {
                    language = first
                    lines.removeFirst()
                }

                let innerCode = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
                let langLower = language?.lowercased()

                if langLower == "markdown" || langLower == "md" {
                    // Do not render markdown as a code snippet. Parse its contents into rich blocks!
                    let nested = parseProse(innerCode)
                    items.append(contentsOf: nested)
                } else {
                    items.append(IdentifiableMarkdownBlock(block: .codeBlock(code: innerCode, language: language)))
                }
            } else {
                // Prose segment
                let proseBlocks = parseProse(part)
                items.append(contentsOf: proseBlocks)
            }
        }

        return items.isEmpty ? [IdentifiableMarkdownBlock(block: .paragraph(content))] : items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(parsedBlocks) { item in
                switch item.block {
                case .heading(let level, let text):
                    MarkdownHeadingView(level: level, text: text)
                case .paragraph(let text):
                    MarkdownParagraphView(text: text)
                case .orderedList(let items):
                    MarkdownOrderedListView(items: items)
                case .unorderedList(let items):
                    MarkdownUnorderedListView(items: items)
                case .blockquote(let text):
                    MarkdownBlockquoteView(text: text)
                case .table(let headers, let rows):
                    MarkdownTableView(headers: headers, rows: rows)
                case .codeBlock(let code, let language):
                    MarkdownCodeBlockView(code: code, language: language)
                case .divider:
                    MarkdownDividerView()
                }
            }
        }
    }

    // MARK: - Outer Fence Unwrapping

    /// Strips enclosing ````markdown ... ```` or ````md ... ```` fences if the LLM wrapped the entire response in one.
    static func unwrapOuterMarkdownFence(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if (lower.hasPrefix("```markdown") || lower.hasPrefix("```md")) && trimmed.hasSuffix("```") && trimmed.count > 6 {
            if let firstNewline = trimmed.firstIndex(of: "\n") {
                let startIndex = trimmed.index(after: firstNewline)
                let endIndex = trimmed.index(trimmed.endIndex, offsetBy: -3)
                if startIndex <= endIndex {
                    return String(trimmed[startIndex..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return input
    }

    // MARK: - Prose Parsing

    private func parseProse(_ text: String) -> [IdentifiableMarkdownBlock] {
        var result: [IdentifiableMarkdownBlock] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 1. Skip blank lines
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // 2. Horizontal rules: ---, ***, ___
            if trimmed == "---" || trimmed == "***" || trimmed == "___" || trimmed == "- - -" || trimmed == "* * *" {
                result.append(IdentifiableMarkdownBlock(block: .divider))
                i += 1
                continue
            }

            // 3. Headings: # through ######
            if trimmed.hasPrefix("#") {
                var level = 0
                for ch in trimmed {
                    if ch == "#" { level += 1 } else { break }
                }
                if level >= 1 && level <= 6 {
                    let remainder = trimmed.dropFirst(level)
                    if remainder.hasPrefix(" ") {
                        let headerText = remainder.trimmingCharacters(in: .whitespaces)
                        result.append(IdentifiableMarkdownBlock(block: .heading(level: level, text: headerText)))
                        i += 1
                        continue
                    }
                }
            }

            // 4. Blockquotes: > ...
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let curTrimmed = lines[i].trimmingCharacters(in: .whitespaces)
                    if curTrimmed.hasPrefix(">") {
                        let stripped = curTrimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                        quoteLines.append(stripped)
                        i += 1
                    } else if !curTrimmed.isEmpty && !quoteLines.isEmpty {
                        quoteLines.append(curTrimmed)
                        i += 1
                    } else {
                        break
                    }
                }
                result.append(IdentifiableMarkdownBlock(block: .blockquote(quoteLines.joined(separator: "\n"))))
                continue
            }

            // 5. Tables: current line has |, next line is table separator
            if trimmed.contains("|") && i + 1 < lines.count && isTableSeparator(lines[i + 1]) {
                let headerCells = parseTableRow(lines[i])
                i += 2 // skip header and divider row
                var rowCells: [[String]] = []
                while i < lines.count {
                    let rowLine = lines[i].trimmingCharacters(in: .whitespaces)
                    if rowLine.contains("|") && !rowLine.isEmpty {
                        rowCells.append(parseTableRow(rowLine))
                        i += 1
                    } else {
                        break
                    }
                }
                result.append(IdentifiableMarkdownBlock(block: .table(headers: headerCells, rows: rowCells)))
                continue
            }

            // 6. Ordered list: 1. Item
            if let (isOrdered, _, firstText) = parseOrderedItem(line), isOrdered {
                var listItems: [String] = [firstText]
                i += 1
                while i < lines.count {
                    let curLine = lines[i]
                    if let (isNextOrdered, _, nextText) = parseOrderedItem(curLine), isNextOrdered {
                        listItems.append(nextText)
                        i += 1
                    } else if !curLine.trimmingCharacters(in: .whitespaces).isEmpty &&
                                (curLine.hasPrefix("  ") || curLine.hasPrefix("\t")) &&
                                !listItems.isEmpty {
                        listItems[listItems.count - 1] += " " + curLine.trimmingCharacters(in: .whitespaces)
                        i += 1
                    } else {
                        break
                    }
                }
                result.append(IdentifiableMarkdownBlock(block: .orderedList(items: listItems)))
                continue
            }

            // 7. Unordered list: - Item, * Item, + Item
            if let (isUnordered, firstText) = parseUnorderedItem(line), isUnordered {
                var listItems: [String] = [firstText]
                i += 1
                while i < lines.count {
                    let curLine = lines[i]
                    if let (isNextUnordered, nextText) = parseUnorderedItem(curLine), isNextUnordered {
                        listItems.append(nextText)
                        i += 1
                    } else if !curLine.trimmingCharacters(in: .whitespaces).isEmpty &&
                                (curLine.hasPrefix("  ") || curLine.hasPrefix("\t")) &&
                                !listItems.isEmpty {
                        listItems[listItems.count - 1] += " " + curLine.trimmingCharacters(in: .whitespaces)
                        i += 1
                    } else {
                        break
                    }
                }
                result.append(IdentifiableMarkdownBlock(block: .unorderedList(items: listItems)))
                continue
            }

            // 8. Regular paragraph
            var pLines: [String] = [trimmed]
            i += 1
            while i < lines.count {
                let nextLine = lines[i]
                let nextTrimmed = nextLine.trimmingCharacters(in: .whitespaces)
                if nextTrimmed.isEmpty {
                    break
                }
                if nextTrimmed.hasPrefix("#") ||
                    nextTrimmed.hasPrefix(">") ||
                    nextTrimmed == "---" ||
                    nextTrimmed == "***" ||
                    (parseOrderedItem(nextLine)?.0 == true) ||
                    (parseUnorderedItem(nextLine)?.0 == true) ||
                    (nextTrimmed.contains("|") && i + 1 < lines.count && isTableSeparator(lines[i + 1])) {
                    break
                }
                pLines.append(nextTrimmed)
                i += 1
            }
            result.append(IdentifiableMarkdownBlock(block: .paragraph(pLines.joined(separator: " "))))
        }

        return result
    }

    private func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return false }
        let allowed = Set("| -:")
        return Set(trimmed).isSubset(of: allowed) && trimmed.contains("-")
    }

    private func parseTableRow(_ line: String) -> [String] {
        var cells = line.components(separatedBy: "|")
        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true && cells.count > 1 {
            cells.removeFirst()
        }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true && !cells.isEmpty {
            cells.removeLast()
        }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func parseOrderedItem(_ line: String) -> (Bool, Int, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let dotIndex = trimmed.firstIndex(of: ".") else { return nil }
        let prefix = trimmed[..<dotIndex].trimmingCharacters(in: .whitespaces)
        guard let num = Int(prefix), num > 0, num < 10000 else { return nil }
        let afterDot = trimmed[trimmed.index(after: dotIndex)...]
        if afterDot.hasPrefix(" ") {
            let text = afterDot.trimmingCharacters(in: .whitespaces)
            return (true, num, text)
        }
        return nil
    }

    private func parseUnorderedItem(_ line: String) -> (Bool, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") {
            return (true, String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        } else if trimmed.hasPrefix("* ") {
            return (true, String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        } else if trimmed.hasPrefix("+ ") {
            return (true, String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}
