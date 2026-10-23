import SwiftUI
import AppKit

/// The separate UI for a model's reasoning.
///
/// Everything the model put inside `<thinking>…</thinking>` tags is shown
/// here — visually distinct from the answer bubble (muted, indented, behind
/// a disclosure), because it is the model's working, not its reply. While a
/// response is still streaming inside an unclosed tag the view stays
/// expanded and labels itself "Thinking…"; once the answer starts it can be
/// collapsed, and it remembers the user's choice per message on screen.
struct ThinkingModelUI: View {
    /// The model's reasoning text (already extracted by `ThinkingContentParser`).
    let thinkingText: String
    /// True while the model is still producing this reasoning.
    var isStreaming: Bool = false

    @State private var isExpanded: Bool?
    @State private var copied = false

    private var expanded: Bool {
        isExpanded ?? isStreaming
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded = !expanded
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.system(size: 11, weight: .semibold))
                    Text(isStreaming ? "Thinking…" : "Thinking")
                        .font(.system(size: 11, weight: .semibold))
                    if isStreaming {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Spacer()
                    Text("\(thinkingText.count) chars")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide the model's reasoning" : "Show the model's reasoning")

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(thinkingText)
                        .font(.system(size: 12))
                        .italic()
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack {
                        Spacer()
                        Button {
                            copyThinking()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                Text(copied ? "Copied" : "Copy thinking")
                            }
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.045), in: .rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            // A quiet left rule marks this as the model's inner monologue,
            // set apart from the answer that follows it.
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.purple.opacity(0.45))
                .frame(width: 3)
                .padding(.vertical, 8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isStreaming ? "Model is thinking" : "Model thinking, \(thinkingText.count) characters")
    }

    private func copyThinking() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(thinkingText, forType: .string)
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { copied = false }
        }
    }
}
