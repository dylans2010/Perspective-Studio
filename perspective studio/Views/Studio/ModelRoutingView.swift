import SwiftUI

/// Model routing (feature J): pick a task, see which installed model the
/// router chooses *and why*, override it manually, or send the choice to Chat.
struct ModelRoutingView: View {
    @Bindable var chatViewModel: ChatViewModel
    @State private var task: RoutingTask = .chat
    @State private var overrideModelID: String?

    private var decision: RoutingDecision? {
        ModelRouter.route(task: task, installedModels: chatViewModel.installedModels, overrideModelID: overrideModelID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("The router scores installed, validated models using evidence only: catalog category and name (capabilities), the vision flag, and a RAM estimate against this Mac's available memory. It never claims a capability without that evidence.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Task", selection: $task) {
                    ForEach(RoutingTask.allCases) { item in
                        Label(item.displayName, systemImage: item.systemImage).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: task) {
                    overrideModelID = ModelRouter.manualOverride(for: task)
                }

                Picker("Manual override", selection: $overrideModelID) {
                    Text("Automatic").tag(nil as String?)
                    ForEach(chatViewModel.installedModels) { model in
                        Text(model.displayName).tag(model.id as String?)
                    }
                }
                .onChange(of: overrideModelID) {
                    ModelRouter.setManualOverride(overrideModelID, for: task)
                }

                if chatViewModel.installedModels.isEmpty {
                    ContentUnavailableView("No Installed Models", systemImage: "arrow.down.circle", description: Text("Download and validate a model first — routing only chooses among complete local models."))
                } else if let decision {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "cpu")
                            Text(decision.model.displayName)
                                .font(.title3)
                                .bold()
                            if decision.isManualOverride {
                                badge("Manual override", color: .blue)
                            } else if decision.usedFallback {
                                badge("Fallback", color: .orange)
                            } else {
                                badge("Best evidence fit", color: .green)
                            }
                        }
                        ForEach(decision.reasons, id: \.self) { reason in
                            Label(reason, systemImage: "checkmark.circle")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Button("Use This Model in Chat") {
                            if let model = chatViewModel.installedModels.first(where: { $0.id == decision.model.id }) {
                                chatViewModel.loadInstalledModel(model)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .background(.regularMaterial)
                    .clipShape(.rect(cornerRadius: 12))
                } else {
                    ContentUnavailableView(
                        "No Model Can Do This Honestly",
                        systemImage: "eye.slash",
                        description: Text("No installed model has evidence for this task (for vision, that means a vision model). The router will not pretend a text model can see images.")
                    )
                }
            }
            .padding()
        }
        .task {
            chatViewModel.scanInstalledModels()
            overrideModelID = ModelRouter.manualOverride(for: task)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(.capsule)
    }
}
