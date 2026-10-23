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
    /// The current Quick Chat run, so it can actually be stopped (and a
    /// new run supersedes the old one instead of two streams writing
    /// into one response).
    @State private var runTask: Task<Void, Never>?
    @State private var activeRunID: UUID?

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
                if isRunning {
                    ProgressView().controlSize(.small)
                    Button {
                        stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Spacer()
                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }

            if !response.isEmpty {
                // Same display rule as the main chat: no raw tool
                // invocations or tool ids in visible text.
                let parsed = ThinkingContentParser.parse(
                    ToolInvocationSanitizer.displayText(for: response, knownToolIDs: ToolsRegistry.shared.allToolIDs)
                )
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

    /// Stops the active Quick Chat run: cancels its task (the stream
    /// loop below checks cancellation per token and the backend stream
    /// tears down via its termination handler) and clears the run id so
    /// any late token from it is dropped by the run-id gate.
    private func stop() {
        runTask?.cancel()
        runTask = nil
        activeRunID = nil
        isRunning = false
    }

    private func run() {
        guard let model = selectedModel else { return }
        // A new run supersedes any run still streaming.
        runTask?.cancel()
        let runID = UUID()
        activeRunID = runID
        isRunning = true
        errorText = nil
        response = ""
        let text = prompt
        let backend = chatViewModel.selectedBackend
        // Quick Chat used to pass `systemPrompt: nil`, so its model knew
        // nothing about its indexed capabilities. It now gets the same
        // index-based prompt as the main chat: the counts-only directory
        // plus the excerpts retrieved for this prompt. Like all Chat
        // surfaces it receives NO project context — memory is Agent-only.
        let globalPrompt = UserDefaults.standard.string(forKey: "customSystemPrompt") ?? ""
        let quickIntent = ConversationRouter.intent(for: text)
        let systemPrompt = ModelContextBuilder.build(
            ModelContextBuilder.Input(
                isAgentMode: false,
                capability: ModelCapabilityProfile.profile(forModelID: model.id, isVisual: model.isVisual),
                intent: quickIntent,
                indexDirectory: ContextIndexManager.directoryText(
                    mode: .chat,
                    globalCustomPrompt: globalPrompt,
                    activeSkillIDs: Set(chatViewModel.activeSkills.map(\.id))
                ),
                retrievedContext: ContextIndexManager.retrievedBundle(
                    query: text,
                    mode: .chat,
                    globalCustomPrompt: globalPrompt,
                    activeSkillIDs: Set(chatViewModel.activeSkills.map(\.id)),
                    intent: quickIntent
                ),
                thinkingEnabled: ThinkingSettings.isEnabled,
                thinkingBudget: ThinkingSettings.budget,
                modelDisplayName: model.displayName,
                projectContext: nil
            )
        )
        runTask = Task {
            do {
                _ = try await backend.load(model: model)
                let rawStream = try backend.stream(prompt: text, systemPrompt: systemPrompt)
                let stream = StreamTimeout.events(rawStream, after: GenerationDefaults.maxChatGenerationDuration)
                for try await event in stream {
                    if Task.isCancelled { break }
                    // Drop late tokens from a stopped/superseded run.
                    guard activeRunID == runID else { break }
                    if case .token(let token) = event {
                        response += token
                    }
                }
            } catch {
                if !Task.isCancelled, activeRunID == runID {
                    errorText = error.localizedDescription
                }
            }
            if activeRunID == runID {
                // Empty completion = explicit failure, never a blank
                // result area that looks like success.
                if !Task.isCancelled, errorText == nil,
                   ThinkingContentParser.visibleContent(of: response).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    errorText = "The model produced no response for that message. Nothing was executed — try again or pick a different model."
                    response = ""
                }
                activeRunID = nil
                isRunning = false
            }
        }
    }
}
