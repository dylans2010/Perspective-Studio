import SwiftUI

public struct ToolCallView: View {
    public let record: ToolCallRecord
    public var onConfirm: (() -> Void)?
    public var onDeny: (() -> Void)?

    @State private var isExpanded: Bool
    @State private var isHovered: Bool = false

    public init(
        record: ToolCallRecord,
        initiallyExpanded: Bool? = nil,
        onConfirm: (() -> Void)? = nil,
        onDeny: (() -> Void)? = nil
    ) {
        self.record = record
        self.onConfirm = onConfirm
        self.onDeny = onDeny
        let defaultExpanded = initiallyExpanded ?? (record.status == .requiresConfirmation)
        _isExpanded = State(initialValue: defaultExpanded)
    }

    public init(
        toolID: String,
        arguments: [String: String] = [:],
        result: String? = nil,
        status: ToolCallStatus = .completed,
        duration: TimeInterval? = nil,
        initiallyExpanded: Bool? = nil,
        onConfirm: (() -> Void)? = nil,
        onDeny: (() -> Void)? = nil
    ) {
        self.init(
            record: ToolCallRecord(
                toolID: toolID,
                arguments: arguments,
                result: result,
                status: status,
                duration: duration
            ),
            initiallyExpanded: initiallyExpanded,
            onConfirm: onConfirm,
            onDeny: onDeny
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            } label: {
                ToolCallCompactRow(record: record, isExpanded: isExpanded)
            }
            .buttonStyle(.plain)

            if isExpanded {
                ToolCallExpandedDrawer(record: record, onConfirm: onConfirm, onDeny: onDeny)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(isHovered ? 0.05 : 0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Subviews

private struct ToolCallCompactRow: View {
    let record: ToolCallRecord
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 8) {
            // Tool Category Icon
            Image(systemName: ToolNameFormatter.iconName(for: record.toolID))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 5))

            // Human-readable activity label (e.g. "Searching files")
            Text(ToolNameFormatter.activityLabel(for: record.toolID))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            // Separator dot and contextual summary if present
            if let summary = record.contextualSummary {
                Text("·")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)

                Text(summary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            // Status indicator + duration
            ToolCallCompactStatusIndicator(record: record)

            // Chevron
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 12)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 34)
        .contentShape(Rectangle())
    }
}

private struct ToolCallCompactStatusIndicator: View {
    let record: ToolCallRecord

    var body: some View {
        switch record.status {
        case .pending:
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Pending")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

        case .running:
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.75)
                Text("Running")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

        case .completed:
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.green)
                if let duration = record.formattedDuration {
                    Text(duration)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

        case .failed:
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                Text("Failed")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

        case .cancelled:
            HStack(spacing: 4) {
                Image(systemName: "nosign")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Cancelled")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

        case .requiresConfirmation:
            ToolCallStatusBadgeView(status: .requiresConfirmation, isCompact: true)
        }
    }
}

private struct ToolCallExpandedDrawer: View {
    let record: ToolCallRecord
    var onConfirm: (() -> Void)?
    var onDeny: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .opacity(0.3)
                .padding(.horizontal, 8)

            // Approval controls if awaiting confirmation
            if record.status == .requiresConfirmation {
                ToolCallConfirmationView(onConfirm: onConfirm, onDeny: onDeny)
                    .padding(.horizontal, 8)
            }

            // Error banner if failed
            if case .failed(let errorMessage) = record.status {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08), in: .rect(cornerRadius: 6))
                .padding(.horizontal, 8)
            }

            // Working directory or file path if available
            if let path = record.arguments["path"]
                ?? record.arguments["filePath"]
                ?? record.arguments["file"]
                ?? record.arguments["dir"]
                ?? record.arguments["cwd"],
               !path.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(path)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 8)
            }

            // Parameters Drawer
            if !record.arguments.isEmpty {
                ToolCallParametersView(arguments: record.arguments)
                    .padding(.horizontal, 8)
            }

            // Output Drawer
            if let result = record.result, !result.isEmpty {
                ToolCallOutputView(output: result)
                    .padding(.horizontal, 8)
            }
        }
        .padding(.bottom, 8)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
