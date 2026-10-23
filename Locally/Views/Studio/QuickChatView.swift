import SwiftUI
import AppKit

/// Compact chat for the menu-bar extra and the Quick Chat window
/// (feature M). Open it from the menu bar, or from anywhere with the global
/// ⇧⌘L hotkey while Locally is running. It uses the same installed models and
/// the same backend as the main window — no separate engine.
struct QuickChatView: View {
    @Bindable var chatViewModel: ChatViewModel
    @State private var prompt = ""
    @State private var response = ""
    @State private var isRunning = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "cpu")
                Picker("Model", selection: $chatViewModel.selectedModelID) {
                    Text("No model").tag(nil as String?)
                    ForEach(chatViewModel.modelChoices) { model in
                        Text(model.displayName).tag(model.id as String?)
                    }
                }
                .onChange(of: chatViewModel.selectedModelID) { _, _ in
                    // Switching in Quick Chat must not leave a stale "ready"
                    // state from the other model.
                    chatViewModel.prepareSelectedModel()
                }
                .labelsHidden()
                Spacer()
                Button("Open Locally") {
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            TextField("Ask anything…", text: $prompt, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .onSubmit { run() }

            HStack {
                Button {
                    run()
                } label: {
                    Label("Generate", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning || prompt.trimmingCharacters(in: .whitespaces).isEmpty || selectedModel == nil)
                if isRunning { ProgressView().controlSize(.small) }
                Spacer()
                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }

            if !response.isEmpty {
                let parsed = ThinkingContentParser.parse(response)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if parsed.hasThinking {
                            ThinkingModelUI(
                                thinkingText: parsed.thinkingText,
                                isStreaming: isRunning && parsed.isThinkingOpen
                            )
                        }
                        if !parsed.answer.isEmpty {
                            Text(parsed.answer)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(minHeight: 80)
            }
        }
        .padding(14)
        .frame(width: 420)
        .task { chatViewModel.scanInstalledModels() }
    }

    private var selectedModel: InstalledModel? {
        chatViewModel.modelChoices.first { $0.id == chatViewModel.selectedModelID }
            ?? chatViewModel.modelChoices.first
    }

    private func run() {
        guard let model = selectedModel else { return }
        isRunning = true
        errorText = nil
        response = ""
        let text = prompt
        let backend = chatViewModel.selectedBackend
        // Quick Chat used to pass `systemPrompt: nil`, so its model knew
        // nothing about its tools, system assets, custom prompt, or skills.
        // It now gets the same awareness prompt as the main chat.
        let systemPrompt = ModelContextBuilder.build(
            ModelContextBuilder.Input(
                globalCustomPrompt: UserDefaults.standard.string(forKey: "customSystemPrompt") ?? "",
                isAgentMode: false,
                includeTools: true,
                compactToolsList: ModelContextBuilder.compactToolsList(from: ToolsRegistry.shared.allTools),
                includeSystemAssets: true,
                systemAssetsIndex: SystemAssetsManager.shared.generatePromptIndex(),
                availableSkills: SkillsManager.shared.skills,
                activeSkills: Array(chatViewModel.activeSkills),
                thinkingEnabled: UserDefaults.standard.bool(forKey: "enableThinkingMode"),
                thinkingBudget: UserDefaults.standard.string(forKey: "thinkingBudget") ?? "medium",
                modelDisplayName: model.displayName
            )
        )
        Task {
            do {
                _ = try await backend.load(model: model)
                let stream = try backend.stream(prompt: text, systemPrompt: systemPrompt)
                for try await event in stream {
                    if case .token(let token) = event {
                        response += token
                    }
                }
            } catch {
                errorText = error.localizedDescription
            }
            isRunning = false
        }
    }
}
