import SwiftUI
import AppKit

public struct ToolCallOutputView: View {
    public let output: String
    @State private var copied: Bool = false

    public init(output: String) {
        self.output = output
    }

    private var isTruncated: Bool {
        output.contains("[truncated]") || output.count > 6000
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Output")
                    .font(.caption2)
                    .bold()
                    .foregroundStyle(.secondary)

                if isTruncated {
                    Text("(truncated)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    copyOutput()
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            ScrollView([.horizontal, .vertical]) {
                Text(output)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 180)
            .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
        .padding(8)
        .background(Color.primary.opacity(0.02), in: .rect(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func copyOutput() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
