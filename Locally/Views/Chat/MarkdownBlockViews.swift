import SwiftUI
import AppKit

// MARK: - Markdown Block Data Model

enum MarkdownBlock: Sendable, Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case orderedList(items: [String])
    case unorderedList(items: [String])
    case blockquote(String)
    case codeBlock(code: String, language: String?)
    case table(headers: [String], rows: [[String]])
    case divider
}

struct IdentifiableMarkdownBlock: Identifiable, Sendable {
    let id = UUID()
    let block: MarkdownBlock
}

// MARK: - Markdown Inline Text Helper

enum MarkdownInlineParser {
    static func attributed(_ text: String) -> AttributedString {
        if let parsed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return parsed
        }
        return AttributedString(text)
    }
}

// MARK: - Block Views

struct MarkdownHeadingView: View {
    let level: Int
    let text: String

    private var font: Font {
        switch level {
        case 1:
            return .system(size: 22, weight: .bold, design: .rounded)
        case 2:
            return .system(size: 18, weight: .bold, design: .rounded)
        case 3:
            return .system(size: 15, weight: .semibold)
        default:
            return .system(size: 14, weight: .semibold)
        }
    }

    var body: some View {
        Text(MarkdownInlineParser.attributed(text))
            .font(font)
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .padding(.top, level <= 2 ? 6 : 2)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MarkdownParagraphView: View {
    let text: String

    var body: some View {
        Text(MarkdownInlineParser.attributed(text))
            .font(.system(size: 14))
            .lineSpacing(3)
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MarkdownOrderedListView: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1).")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 20, alignment: .trailing)

                    Text(MarkdownInlineParser.attributed(items[index]))
                        .font(.system(size: 14))
                        .lineSpacing(2)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct MarkdownUnorderedListView: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(Color.primary.opacity(0.6))
                        .frame(width: 5, height: 5)
                        .padding(.top, 5)

                    Text(MarkdownInlineParser.attributed(items[index]))
                        .font(.system(size: 14))
                        .lineSpacing(2)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct MarkdownBlockquoteView: View {
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor)
                .frame(width: 3)

            Text(MarkdownInlineParser.attributed(text))
                .font(.system(size: 13))
                .italic()
                .lineSpacing(2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.06), in: .rect(cornerRadius: 6))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                if !headers.isEmpty {
                    GridRow {
                        ForEach(headers.indices, id: \.self) { index in
                            Text(MarkdownInlineParser.attributed(headers[index]))
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                    }

                    Divider()
                        .gridCellUnsizedAxes(.horizontal)
                }

                ForEach(rows.indices, id: \.self) { rowIndex in
                    GridRow {
                        ForEach(rows[rowIndex].indices, id: \.self) { colIndex in
                            Text(MarkdownInlineParser.attributed(rows[rowIndex][colIndex]))
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }

                    if rowIndex < rows.count - 1 {
                        Divider()
                            .gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .scrollIndicators(.hidden)
    }
}

struct MarkdownCodeBlockView: View {
    let code: String
    let language: String?

    @State private var copied: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let language, !language.isEmpty {
                    Text(language.lowercased())
                        .font(.caption2.monospaced())
                        .bold()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08), in: .capsule)
                }
                Spacer()
                Button {
                    copyCode()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied" : "Copy")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
        .padding(12)
        .background(Color.black.opacity(0.35), in: .rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func copyCode() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(code, forType: .string)
        withAnimation {
            copied = true
        }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation {
                copied = false
            }
        }
    }
}

struct MarkdownDividerView: View {
    var body: some View {
        Divider()
            .padding(.vertical, 4)
    }
}
