import SwiftUI

public struct ToolCallStatusBadgeView: View {
    public let status: ToolCallStatus
    public let isCompact: Bool

    public init(status: ToolCallStatus, isCompact: Bool = false) {
        self.status = status
        self.isCompact = isCompact
    }

    public var body: some View {
        if isCompact {
            switch status {
            case .pending:
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Pending")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

            case .running:
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.8)
                    Text("Running")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

            case .completed:
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.green)

            case .failed:
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                    Text("Failed")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }

            case .cancelled:
                HStack(spacing: 3) {
                    Image(systemName: "nosign")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Cancelled")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

            case .requiresConfirmation:
                HStack(spacing: 4) {
                    Image(systemName: "hand.raised.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("Approval")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.15), in: .capsule)
            }
        } else {
            switch status {
            case .pending:
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Pending")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: .capsule)

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

            case .cancelled:
                HStack(spacing: 4) {
                    Image(systemName: "nosign")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Cancelled")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.12), in: .capsule)

            case .requiresConfirmation:
                HStack(spacing: 4) {
                    Image(systemName: "hand.raised.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("Approval")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.15), in: .capsule)
            }
        }
    }
}
