import SwiftUI
import AppKit

public struct ToolCallOutputView: View {
    public let output: String
    @State private var copied: Bool = false

    public init(output: String) {
        self.output = output
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Output")
                    .font(.caption)
                    .bold()
                    .foregroundStyle(.secondary)
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
            .frame(maxHeight: 200)
            .background(Color.black.opacity(0.2), in: .rect(cornerRadius: 6))
        }
        .padding(10)
        .background(Color.primary.opacity(0.03), in: .rect(cornerRadius: 8))
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
