import SwiftUI

public struct ToolCallView: View {
    public let record: ToolCallRecord
    public var onConfirm: (() -> Void)?
    public var onDeny: (() -> Void)?

    @State private var isExpanded: Bool

    public init(
        record: ToolCallRecord,
        initiallyExpanded: Bool? = nil,
        onConfirm: (() -> Void)? = nil,
        onDeny: (() -> Void)? = nil
    ) {
        self.record = record
        self.onConfirm = onConfirm
        self.onDeny = onDeny
        let defaultExpanded = initiallyExpanded ?? (record.status == .requiresConfirmation || record.status == .running)
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
            // Header button toggles drawer
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    // Tool Category Icon
                    Image(systemName: ToolNameFormatter.iconName(for: record.toolID))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.08), in: .circle)

                    // Humanized Action Title (never raw technical tool names)
                    Text(ToolNameFormatter.format(record.toolID))
                        .font(.subheadline)
                        .bold()
                        .foregroundStyle(.primary)

                    Spacer(minLength: 8)

                    // Duration if available
                    if let durationString = record.formattedDuration {
                        Text(durationString)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    // Live Status Badge
                    ToolCallStatusBadgeView(status: record.status)

                    // Expand / Collapse Chevron
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .bold()
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            // Expandable Drawer
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                        .opacity(0.5)
                        .padding(.horizontal, 10)

                    // Confirmation banner & actions if awaiting user permission
                    if record.status == .requiresConfirmation {
                        ToolCallConfirmationView(onConfirm: onConfirm, onDeny: onDeny)
                            .padding(.horizontal, 10)
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
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.1), in: .rect(cornerRadius: 8))
                        .padding(.horizontal, 10)
                    }

                    // Parameters Drawer
                    ToolCallParametersView(arguments: record.arguments)
                        .padding(.horizontal, 10)

                    // Output Drawer
                    if let result = record.result, !result.isEmpty {
                        ToolCallOutputView(output: result)
                            .padding(.horizontal, 10)
                    }
                }
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .liquidGlass(.rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}
