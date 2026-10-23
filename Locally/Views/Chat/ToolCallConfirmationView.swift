import SwiftUI

public struct ToolCallConfirmationView: View {
    public var onConfirm: (() -> Void)?
    public var onDeny: (() -> Void)?

    public init(onConfirm: (() -> Void)? = nil, onDeny: (() -> Void)? = nil) {
        self.onConfirm = onConfirm
        self.onDeny = onDeny
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text("This action requires your confirmation before proceeding.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 10) {
                Button("Approve & Run", systemImage: "checkmark") {
                    onConfirm?()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Decline", systemImage: "xmark", role: .destructive) {
                    onDeny?()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.1), in: .rect(cornerRadius: 8))
    }
}
