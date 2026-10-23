import SwiftUI
import AppKit

/// Renders a chat message with Markdown (feature G): prose goes through
/// Foundation's Markdown parser (bold/italic/inline code/links), and fenced
/// code blocks render as monospaced panels with a copy button — instead of
/// the previous plain `Text`, which showed raw `**` and backticks.
struct MarkdownContentView: View {
    let content: String

    private enum Segment {
        case prose(String)
        case code(String, language: String?)
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        let parts = content.components(separatedBy: "```")
        for (index, part) in parts.enumerated() {
            if index % 2 == 1 {
                // Fenced block: first line may be the language name.
                var lines = part.components(separatedBy: "\n")
                var language: String?
                if let first = lines.first, !first.contains(" "), first.count <= 20, !first.isEmpty {
                    language = first
                    lines.removeFirst()
                }
                result.append(.code(lines.joined(separator: "\n").trimmingCharacters(in: .newlines), language: language))
            } else if !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(.prose(part))
            }
        }
        return result.isEmpty ? [.prose(content)] : result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let text):
                    Text(attributed(text))
                        .textSelection(.enabled)
                case .code(let code, let language):
                    codeBlock(code, language: language)
                }
            }
        }
    }

    private func attributed(_ text: String) -> AttributedString {
        if let parsed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return parsed
        }
        return AttributedString(text)
    }

    private func codeBlock(_ code: String, language: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let language {
                    Text(language)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            .scrollIndicators(.hidden)
        }
        .padding(10)
        .background(Color.black.opacity(0.25))
        .clipShape(.rect(cornerRadius: 8))
    }
}
