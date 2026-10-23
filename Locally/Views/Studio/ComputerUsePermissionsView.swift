import SwiftUI

/// Computer Use permissions panel, shown inside the existing Tools
/// studio screen (not a separate demo surface): the live Accessibility
/// and Screen Recording states from `ComputerUsePermissions`, the
/// system's own request flow, and a direct route to the exact System
/// Settings pane. States are re-read on appear and on demand because
/// TCC changes happen outside the app.
struct ComputerUsePermissionsView: View {
    @State private var statuses: [ComputerUsePermissionStatus] = ComputerUsePermissions.allStatuses()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Computer Use Permissions").font(.headline)
                Spacer()
                Button("Recheck") { refresh() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Text("Agent mode can operate the desktop with the computer_* tools (screenshots, accessibility, mouse, keyboard, windows). macOS requires these two permissions; everything Computer Use does goes through them, and nothing is requested beyond them.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(statuses, id: \.kind.rawValue) { status in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: status.state == .granted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .foregroundStyle(status.state == .granted ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(status.kind.rawValue).bold()
                            Text(status.state.label)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(status.state == .granted ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                                .foregroundStyle(status.state == .granted ? .green : .orange)
                                .clipShape(.capsule)
                        }
                        Text(status.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if status.state != .granted {
                        VStack(alignment: .trailing, spacing: 6) {
                            Button("Request") {
                                ComputerUsePermissions.request(status.kind)
                                refresh()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Button("Open Settings") {
                                ComputerUsePermissions.openSettings(for: status.kind)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(10)
                .background(.regularMaterial)
                .clipShape(.rect(cornerRadius: 10))
            }

            Text("Screen Recording may require relaunching Locally after it is granted. An active Computer Use task can be stopped at any time by cancelling the agent run — cancellation stops new actions from being dispatched.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        statuses = ComputerUsePermissions.allStatuses()
    }
}
