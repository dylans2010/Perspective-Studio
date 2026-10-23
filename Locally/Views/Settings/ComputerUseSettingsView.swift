import SwiftUI

/// Settings > Computer Use.
///
/// The control centre for Locally's desktop automation: what it is,
/// the master on/off switch (the same `computerUseEnabled` defaults
/// key the tool layer enforces in `ComputerUseService.gate`), and the
/// two macOS permissions it needs, with the system request flow and
/// deep links to the exact System Settings panes.
///
/// Computer Use is off by default. Turning the switch off stops every
/// `computer_*` tool at its next call — permissions already granted
/// to Locally in macOS Settings are unaffected and can be revoked
/// there at any time.
struct ComputerUseSettingsView: View {
    @AppStorage(ComputerUseSettings.enabledKey) private var computerUseEnabled: Bool = false
    @State private var statuses: [ComputerUsePermissionStatus] = ComputerUsePermissions.allStatuses()

    private var missingPermissions: [ComputerUsePermissionStatus] {
        statuses.filter { $0.state != .granted }
    }

    private var readinessText: String {
        if !computerUseEnabled {
            return "Off. The agent cannot see your screen or control any app."
        }
        if missingPermissions.isEmpty {
            return "On and ready. In Agent mode the model can use the computer_* tools; you can stop a run at any time by cancelling it."
        }
        let names = missingPermissions.map { $0.kind.rawValue }.joined(separator: " and ")
        return "On, but not ready — \(names) still need\(missingPermissions.count == 1 ? "s" : "") to be granted below before the tools that need \(missingPermissions.count == 1 ? "it" : "them") can work."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Computer Use")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)

            aboutCard
            enableCard
            permissionsCard
            safetyCard
        }
        .onAppear { refresh() }
    }

    // MARK: - What is Computer Use?

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What is Computer Use?")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 10) {
                Text("Computer Use lets the model in Agent mode operate this Mac's desktop the way a person would: it looks at the screen, decides on one action, carries it out, and checks the result — repeating until the task is done, blocked, or you stop it.")
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)

                capabilityRow(icon: "eye", text: "See — screenshots, on-device text recognition (OCR), and apps' accessibility trees show it what's on screen and where things are.")
                capabilityRow(icon: "cursorarrow.click", text: "Act — mouse clicks, scrolling and dragging, keyboard typing and shortcuts, all sent as real macOS input events.")
                capabilityRow(icon: "macwindow.on.rectangle", text: "Control apps & windows — launch, focus and close apps; move, resize, minimize and restore windows.")

                Text("Everything runs on this Mac through macOS frameworks (ScreenCaptureKit, Accessibility, Vision). Nothing about your screen is sent anywhere by Locally itself — the model you're chatting with is the only thing that receives tool results, exactly like any other tool.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .liquidGlass(.rect(cornerRadius: 12))
        }
    }

    private func capabilityRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    // MARK: - Master switch

    private var enableCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enable")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)

            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Computer Use")
                            .font(.system(size: 13))
                        Text(readinessText)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: $computerUseEnabled)
                        .labelsHidden()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .liquidGlass(.rect(cornerRadius: 12))
        }
    }

    // MARK: - Permissions

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Permissions")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Button("Recheck") { refresh() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            VStack(spacing: 0) {
                ForEach(Array(statuses.enumerated()), id: \.element.kind.rawValue) { index, status in
                    if index > 0 { Divider() }
                    permissionRow(status)
                }
            }
            .liquidGlass(.rect(cornerRadius: 12))

            Text("These are the only two permissions Computer Use needs — it never asks for Full Disk Access or Input Monitoring, and it cannot grant permissions to itself. You can revoke either one at any time in System Settings > Privacy & Security; the tools will simply start reporting it as missing. Screen Recording may require relaunching Locally after you grant it.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func permissionRow(_ status: ComputerUsePermissionStatus) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: status.state == .granted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.system(size: 14))
                .foregroundStyle(status.state == .granted ? .green : .orange)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(status.kind.rawValue)
                        .font(.system(size: 13, weight: .medium))
                    Text(status.state.label)
                        .font(.system(size: 11))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(status.state == .granted ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                        .foregroundStyle(status.state == .granted ? .green : .orange)
                        .clipShape(.capsule)
                }
                Text(status.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Safety

    private var safetyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How it stays safe")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 8) {
                safetyRow("The agent works in a loop — observe, act once, verify — and must check results instead of assuming an action worked.")
                safetyRow("Text on your screen is treated as data, never as instructions to the agent.")
                safetyRow("Apps are only ever closed gracefully — never force-quit — so unsaved-work dialogs stay your decision.")
                safetyRow("Text the agent types is never written to logs or shown back in tool results.")
                safetyRow("Cancelling a run stops new actions from being dispatched immediately.")
            }
            .padding(14)
            .liquidGlass(.rect(cornerRadius: 12))
        }
    }

    private func safetyRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private func refresh() {
        statuses = ComputerUsePermissions.allStatuses()
    }
}
