import SwiftUI
import AppKit

public struct ToolCallParametersView: View {
    public let arguments: [String: String]
    @State private var copied: Bool = false

    public init(arguments: [String: String]) {
        self.arguments = arguments
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Parameters")
                    .font(.caption)
                    .bold()
                    .foregroundStyle(.secondary)
                Spacer()
                if !arguments.isEmpty {
                    Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        copyArguments()
                    }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }

            if arguments.isEmpty {
                Text("No parameters required")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(arguments.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(ToolNameFormatter.formatArgumentKey(key))
                                .font(.caption2)
                                .bold()
                                .foregroundStyle(.secondary)

                            ScrollView(.horizontal) {
                                Text(value)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                            }
                            .scrollIndicators(.hidden)
                            .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 6))
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.03), in: .rect(cornerRadius: 8))
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
