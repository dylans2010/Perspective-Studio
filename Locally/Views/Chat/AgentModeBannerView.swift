import SwiftUI

/// The unmistakable Agent-mode chrome.
///
/// Chat and Agent used to differ only by a tinted pill in the mode switcher
/// and the composer's placeholder text — easy to miss, so users couldn't
/// tell which mode a conversation was in. When Agent mode is on, this
/// banner sits directly under the top control bar for the whole session and
/// shows, live:
///
/// - that the model can call tools (with the real registered-tool count),
/// - the harness status / active tool while a turn runs,
/// - how many system assets and active skills are in play,
/// - a one-tap way back to Chat mode.
///
/// Every number here comes from the real registries/managers, not literals.
struct AgentModeBannerView: View {
    @Bindable var chatViewModel: ChatViewModel
    @State private var harness = AntigravityAgentHarness.shared
    @State private var toolsRegistry = ToolsRegistry.shared
    @State private var systemAssets = SystemAssetsManager.shared
    @State private var projectsStore = AgentProjectsStore.shared

    private var statusText: String {
        if chatViewModel.isGenerating {
            return harness.status.displayText
        }
        return "Ready — describe a task and the agent will plan, call tools, and report back."
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "cpu.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.cyan)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("AGENT MODE")
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(0.6)
                        .foregroundStyle(.cyan)
                    if harness.isRunning, let activeTool = harness.activeToolName {
                        // Human action name only — never the raw tool id.
                        Text("· \(ToolNameFormatter.format(activeTool))")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Live capability chips: what this agent turn actually has.
            HStack(spacing: 6) {
                if let project = projectsStore.selectedProject {
                    capabilityChip(icon: "folder.fill", label: project.name)
                }
                capabilityChip(icon: "wrench.and.screwdriver.fill", label: "\(toolsRegistry.allTools.count) tools")
                capabilityChip(icon: "doc.text.fill", label: "\(systemAssets.availableAssets().count) assets")
                capabilityChip(icon: "sparkles", label: "\(chatViewModel.activeSkills.count) skills")
            }
            .help("Project, tools, system assets, and active skills available to the agent in this mode")

            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    chatViewModel.isAgentMode = false
                }
            } label: {
                Text("Switch to Chat")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.cyan.opacity(0.14), in: .capsule)
            }
            .buttonStyle(.plain)
            .help("Return to plain chat (no tool execution)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            LinearGradient(
                colors: [Color.cyan.opacity(0.16), Color.purple.opacity(0.10)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.cyan.opacity(0.35))
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Agent mode is on. \(statusText)")
    }

    private func capabilityChip(icon: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(label)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(.cyan)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.cyan.opacity(0.12), in: .capsule)
        .overlay(Capsule().stroke(Color.cyan.opacity(0.25), lineWidth: 1))
    }
}
