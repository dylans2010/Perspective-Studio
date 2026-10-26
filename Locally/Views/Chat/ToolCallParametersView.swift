import SwiftUI
import AppKit

public struct ToolCallParametersView: View {
    public let arguments: [String: String]
    @State private var copied: Bool = false

    public init(arguments: [String: String]) {
        self.arguments = arguments
    }

    public var body: some View {
        if arguments.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Parameters")
                        .font(.caption2)
                        .bold()
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        copyArguments()
                    }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(arguments.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        HStack(alignment: .top, spacing: 6) {
                            Text(ToolNameFormatter.formatArgumentKey(key) + ":")
                                .font(.system(.caption2, design: .monospaced))
                                .bold()
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            Text(value)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 2)
                        .padding(.horizontal, 6)
                        .background(Color.primary.opacity(0.03), in: .rect(cornerRadius: 4))
                    }
                }
            }
            .padding(8)
            .background(Color.primary.opacity(0.02), in: .rect(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
    }

    private func copyArguments() {
        let text = arguments.map { "\(ToolNameFormatter.formatArgumentKey($0.key)): \($0.value)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
