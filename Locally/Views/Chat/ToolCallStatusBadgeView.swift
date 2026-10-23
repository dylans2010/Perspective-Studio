import SwiftUI

public struct ToolCallStatusBadgeView: View {
    public let status: ToolCallStatus

    public init(status: ToolCallStatus) {
        self.status = status
    }

    public var body: some View {
        switch status {
        case .running:
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.small)
                Text("Running")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.12), in: .capsule)

        case .completed:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                Text("Done")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.green.opacity(0.12), in: .capsule)

        case .failed:
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                Text("Failed")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.red.opacity(0.12), in: .capsule)

        case .requiresConfirmation:
            HStack(spacing: 4) {
                Image(systemName: "hand.raised.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Text("Approval Required")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.orange.opacity(0.15), in: .capsule)
        }
    }
}
