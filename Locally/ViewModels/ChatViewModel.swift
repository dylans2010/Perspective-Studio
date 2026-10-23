import Foundation
import SwiftData
import SwiftUI
import AppKit
import Accessibility

enum ModelLoadingState: Sendable {
    case idle
    case downloading(Double)
    case loading
    case ready(String)
    case error(String)

    func statusText(for level: ExperienceLevel) -> String {
        switch self {
        case .idle:
            return level == .beginner ? "No model selected" : "Idle"
        case .downloading(let progress):
            let percent = Int(progress * 100)
            return level == .beginner ? "Downloading... \(percent)%" : "Downloading model... \(percent)%"
        case .loading:
            return level == .beginner ? "Getting the AI ready..." : "Loading model into memory..."
        case .ready(let name):
            return level == .beginner ? "Ready to chat!" : "Model loaded: \(name)"
        case .error(let message):
            return level == .beginner ? "Something went wrong" : "Error: \(message)"
        }
    }
}

@Observable @MainActor
final class ChatViewModel {
    var selectedConversation: Conversation?
    var messageText: String = ""
    var isGenerating: Bool = false
    var isSummarizing: Bool = false
    var modelState: ModelLoadingState = .idle
    var selectedModelID: String?
    var selectedModelIsVisual: Bool = false
    var availableModels: [HFModel] = []
    var newModels: [HFModel] = []
    var isLoadingModels: Bool = false
    var attachedVideoURL: URL?
    var attachedFileURLs: [URL] = []
    var attachedImageURLs: [URL] = []
    var installedModels: [InstalledModel] = []
    var activeSkills: Set<AgentSkill> = []
    var downloadErrors: [String: String] = [:]
    var isAgentMode: Bool = false
    var liveToolCalls: [ToolCallRecord] = []
    var messageToolCalls: [UUID: [ToolCallRecord]] = [:]

    private var generationTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var lastAnnouncedMilestone: Int = 0

    func toggleSkill(_ skill: AgentSkill) {
        if activeSkills.contains(skill) {
            activeSkills.remove(skill)
        } else {
            activeSkills.insert(skill)
        }
    }

    func isSkillActive(_ skill: AgentSkill) -> Bool {
        activeSkills.contains(skill)
    }

    // MARK: - Model choices (built-in Apple model + downloaded MLX models)

    /// Models offered in the chat picker: the built-in Apple model first, then
    /// everything the user has downloaded. The Apple model is only listed on
    /// systems that have Foundation Models at all.
    var modelChoices: [InstalledModel] {
        var choices = installedModels
        if AppleFoundationModel.availability != .unsupportedSystem {
            choices.insert(AppleFoundationModel.descriptor, at: 0)
        }
        return choices
    }

    var appleModelAvailability: AppleModelAvailability {
        AppleFoundationModel.availability
    }

    /// The backend that can actually serve the selected model.
    var selectedBackend: any InferenceBackend {
        InferenceBackends.backend(forModelID: selectedModelID)
    }

    /// Brings the loading state in line with a picker that writes
    /// `selectedModelID` directly (Quick Chat, menu bar).
    func prepareSelectedModel() {
        guard let id = selectedModelID else {
            selectedModelIsVisual = false
            modelState = .idle
            return
        }
        if AppleFoundationModel.isAppleModel(id) {
            selectAppleModel()
            return
        }
        guard let model = installedModels.first(where: { $0.id == id }) else { return }
        loadInstalledModel(model)
    }

    func displayName(for modelID: String?) -> String? {
        guard let modelID else { return nil }
        if AppleFoundationModel.isAppleModel(modelID) {
            return AppleFoundationModel.displayName
        }
        return installedModels.first(where: { $0.id == modelID })?.displayName
            ?? modelID.replacingOccurrences(of: "mlx-community/", with: "")
    }

    /// Selects the built-in Apple Intelligence model without loading anything
    /// from disk. Used both by the picker and as the no-models fallback.
    func selectAppleModel() {
        loadTask?.cancel()
        selectedModelID = AppleFoundationModel.modelID
        selectedModelIsVisual = false

        let availability = AppleFoundationModel.availability
        guard availability.isAvailable else {
            modelState = .error(availability.explanation)
            return
        }

        modelState = .ready(AppleFoundationModel.displayName)
        Task {
            _ = try? await InferenceBackends.apple.load(model: AppleFoundationModel.descriptor)
        }
    }

    func fetchModels() async {
        isLoadingModels = true
        do {
            async let allModels = HuggingFaceService.shared.fetchMLXModels()
            async let recentModels = HuggingFaceService.shared.fetchNewMLXModels()
            availableModels = try await allModels
            newModels = try await recentModels
        } catch {
            print("Failed to fetch models: \(error)")
        }
        isLoadingModels = false
    }

    func sendMessage(in context: ModelContext) {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let conversation = selectedConversation else { return }

        // Check if we have installed models; with none, `scanInstalledModels`
        // selects the built-in Apple model as the default.
        if installedModels.isEmpty {
            scanInstalledModels()
        }

        // If a model is not yet loaded into memory, auto-load the current or first installed model
        if case .ready = modelState {
            // Already ready, continue
        } else if AppleFoundationModel.isAppleModel(selectedModelID) {
            let availability = AppleFoundationModel.availability
            guard availability.isAvailable else {
                let warning = Message(role: .system, content: availability.explanation)
                warning.conversation = conversation
                conversation.messages.append(warning)
                try? context.save()
                return
            }
            // The system model is always resident: nothing to download or load.
            modelState = .ready(AppleFoundationModel.displayName)
        } else {
            let candidateModel: InstalledModel? = {
                if let sel = selectedModelID, let match = installedModels.first(where: { $0.id == sel }) {
                    return match
                }
                return installedModels.first
            }()

            guard let modelToLoad = candidateModel else {
                // Nothing downloaded: fall back to the built-in Apple model.
                if AppleFoundationModel.isAvailable {
                    selectAppleModel()
                } else {
                    let warning = Message(
                        role: .system,
                        content: "No downloaded models found on this Mac, and the built-in Apple model is unavailable: \(AppleFoundationModel.availability.explanation)"
                    )
                    warning.conversation = conversation
                    conversation.messages.append(warning)
                    try? context.save()
                }
                return
            }

            // Automatically trigger model load and proceed once ready
            selectedModelID = modelToLoad.id
            selectedModelIsVisual = modelToLoad.isVisual
            modelState = .loading

            let videoURL = attachedVideoURL
            let fileURLs = attachedFileURLs
            let imageURLs = attachedImageURLs
            messageText = ""
            attachedVideoURL = nil
            attachedFileURLs = []
            attachedImageURLs = []

            Task {
                do {
                    let stream = try await LLMService.shared.loadModelByID(modelToLoad.id, isVideoModel: modelToLoad.isVisual)
                    for try await progress in stream {
                        modelState = .downloading(progress)
                    }
                    modelState = .loading
                    try await LLMService.shared.finishLoading()
                    modelState = .ready(modelToLoad.displayName)

                    // Now proceed with sending message
                    await processAndSend(text: text, videoURL: videoURL, fileURLs: fileURLs, imageURLs: imageURLs, in: conversation, context: context)
                } catch {
                    modelState = .error(error.localizedDescription)
                    let warning = Message(role: .system, content: "Could not load \(modelToLoad.displayName): \(error.localizedDescription)")
                    warning.conversation = conversation
                    conversation.messages.append(warning)
                    try? context.save()
                }
            }
            return
        }

        let videoURL = attachedVideoURL
        let fileURLs = attachedFileURLs
        let imageURLs = attachedImageURLs
        messageText = ""
        attachedVideoURL = nil
        attachedFileURLs = []
        attachedImageURLs = []

        Task {
            await processAndSend(text: text, videoURL: videoURL, fileURLs: fileURLs, imageURLs: imageURLs, in: conversation, context: context)
        }
    }

    /// Knowledge-base passages retrieved for the pending turn (injected into
    /// the system prompt by `generateResponse`, with citations).
    private var pendingKnowledgeContext: String?

    private func processAndSend(text: String, videoURL: URL?, fileURLs: [URL], imageURLs: [URL] = [], in conversation: Conversation, context: ModelContext) async {
        // Read file contents off the main thread
        var parts: [String] = []

        if let url = videoURL {
            parts.append("📹 \(url.lastPathComponent)")
        }

        for fileURL in fileURLs {
            let name = fileURL.lastPathComponent
            let content = await Task.detached(priority: .userInitiated) {
                try? String(contentsOf: fileURL, encoding: .utf8)
            }.value
            if let content {
                let trimmed = content.count > 10_000 ? String(content.prefix(10_000)) + "\n…(truncated)" : content
                parts.append("📎 \(name)\n```\n\(trimmed)\n```")
            } else {
                parts.append("📎 \(name) (could not read file)")
            }
        }

        // Images (feature H): only vision models receive them. For any other
        // model the attachment is *not* silently dropped or read as text —
        // the user gets an explicit note and the turn proceeds text-only.
        var persistedImageNames: [String] = []
        if !imageURLs.isEmpty {
            if selectedModelIsVisual {
                for imageURL in imageURLs {
                    parts.append("🖼 \(imageURL.lastPathComponent)")
                    if let storedName = Self.persistImageAttachment(imageURL) {
                        persistedImageNames.append(storedName)
                    }
                }
            } else {
                parts.append("⚠️ \(imageURLs.count) image(s) attached, but the selected model does not support images, so they were not sent. Switch to a vision model (Downloads → look for the Vision badge) to use them.")
            }
        }

        parts.append(text)

        // Knowledge-base retrieval (feature I) when the user enabled it:
        // passages are injected as cited context for this turn only.
        pendingKnowledgeContext = nil
        if UserDefaults.standard.bool(forKey: "knowledgeUseInChat") {
            pendingKnowledgeContext = KnowledgeBaseStore.shared.contextBlock(for: text)
        }

        let displayContent = parts.joined(separator: "\n\n")

        let userMessage = Message(role: .user, content: displayContent)
        userMessage.imageFileNames = persistedImageNames
        userMessage.conversation = conversation
        conversation.messages.append(userMessage)
        conversation.updatedAt = .now

        if conversation.title == "New Conversation" {
            let maxLen = 40
            if text.count <= maxLen {
                conversation.title = text
            } else {
                let truncated = String(text.prefix(maxLen))
                if let lastSpace = truncated.lastIndex(of: " ") {
                    conversation.title = String(truncated[..<lastSpace]) + "…"
                } else {
                    conversation.title = truncated + "…"
                }
            }
        }

        try? context.save()

        generateResponse(for: conversation, in: context, videoURLs: videoURL.map { [$0] } ?? [])
    }

    private func generateResponse(for conversation: Conversation, in context: ModelContext, videoURLs: [URL] = []) {
        let assistantMessage = Message(role: .assistant, content: "")
        assistantMessage.conversation = conversation
        conversation.messages.append(assistantMessage)

        isGenerating = true
        AccessibilityNotification.Announcement("Generating response").post()

        if isAgentMode {
            generationTask = Task {
                await generateAgentResponse(for: conversation, assistantMessage: assistantMessage, in: context)
            }
            return
        }

        let contextLength = UserDefaults.standard.integer(forKey: "defaultContextLength")
        let effectiveContextLength = contextLength > 0 ? contextLength : 4096

        generationTask = Task {
            do {
                // Auto-summarize if approaching context limit
                let lastUserContent = conversation.sortedMessages.last(where: { $0.role == .user })?.content ?? ""
                if ContextSummarizationService.needsSummarization(
                    conversation: conversation,
                    pendingUserMessage: lastUserContent,
                    contextLength: effectiveContextLength
                ) {
                    if let summaryPrompt = ContextSummarizationService.buildSummarizationPrompt(for: conversation) {
                        isSummarizing = true
                        // Summarize on whichever engine the conversation uses;
                        // the Apple model has no MLX container to summarize with.
                        let rawSummary: String
                        if AppleFoundationModel.isAppleModel(selectedModelID) {
                            rawSummary = try await InferenceBackends.apple
                                .generate(prompt: summaryPrompt, systemPrompt: nil).text
                        } else {
                            rawSummary = try await LLMService.shared.summarize(prompt: summaryPrompt)
                        }
                        let summary = ContextSummarizationService.cleanSummary(rawSummary)
                        conversation.runningSummary = summary
                        conversation.lastSummarizedMessageCount = conversation.messages.count - ContextSummarizationService.recentMessagesToKeep

                        // Insert a system message so the user sees that context was condensed
                        let note = Message(role: .system, content: "Earlier messages have been condensed to preserve context.")
                        note.conversation = conversation
                        conversation.messages.append(note)

                        try? context.save()
                        isSummarizing = false
                    }
                }

                let messages = ContextSummarizationService.buildContextualPrompt(
                    conversation: conversation,
                    userMessage: lastUserContent
                )

                // The effective system prompt is assembled in ONE place
                // from the context index: the counts-only directory plus
                // the small bundle of excerpts the local retriever picked
                // for this message (custom-prompt chunks, skill excerpts,
                // asset summaries) — plus this turn's knowledge passages
                // and the <thinking> format instruction. Nothing is
                // injected in full any more: no tool list, no asset index,
                // no skill markdown dump, no whole custom prompt. And Chat
                // mode gets NO project context at all — the Memory system
                // is Agent-mode only, so no project block is built here.
                let knowledge = pendingKnowledgeContext
                pendingKnowledgeContext = nil
                let globalPrompt = UserDefaults.standard.string(forKey: "customSystemPrompt") ?? ""
                let conversationPrompt = conversation.systemPrompt ?? ""
                let activeSkillIDs = Set(activeSkills.map(\.id))
                // The router classifies the turn BEFORE any retrieval:
                // conversational turns get no directory and a standing-
                // instructions-only bundle, so a greeting cannot be
                // answered with a capability recitation.
                let intent = ConversationRouter.intent(for: lastUserContent)
                let effectiveSystemPrompt = ModelContextBuilder.build(
                    ModelContextBuilder.Input(
                        isAgentMode: false,
                        intent: intent,
                        indexDirectory: ContextIndexManager.directoryText(
                            mode: .chat,
                            globalCustomPrompt: globalPrompt,
                            conversationCustomPrompt: conversationPrompt,
                            activeSkillIDs: activeSkillIDs
                        ),
                        retrievedContext: ContextIndexManager.retrievedBundle(
                            query: lastUserContent,
                            mode: .chat,
                            globalCustomPrompt: globalPrompt,
                            conversationCustomPrompt: conversationPrompt,
                            activeSkillIDs: activeSkillIDs,
                            intent: intent
                        ),
                        thinkingEnabled: ThinkingSettings.isEnabled,
                        thinkingBudget: ThinkingSettings.budget,
                        knowledgeContext: knowledge,
                        modelDisplayName: displayName(for: selectedModelID),
                        projectContext: nil
                    )
                )

                // Re-attach this turn's images (persisted copies) for vision models.
                let lastUserMessage = conversation.sortedMessages.last(where: { $0.role == .user })
                let turnImageURLs: [URL] = (lastUserMessage?.imageFileNames ?? []).map {
                    Self.attachmentsDirectory.appendingPathComponent($0)
                }

                var buffer = ""
                var lastFlush = Date.now

                func flushPendingTokens(force: Bool) {
                    let now = Date.now
                    guard !buffer.isEmpty, force || now.timeIntervalSince(lastFlush) >= 0.08 else { return }
                    assistantMessage.content += buffer
                    buffer = ""
                    lastFlush = now
                }

                if AppleFoundationModel.isAppleModel(selectedModelID) {
                    // A fresh session per turn, so the self-contained contextual
                    // prompt carries the conversation history.
                    let events = try InferenceBackends.apple.stream(
                        prompt: Self.transcript(from: messages, skipping: conversation.systemPrompt),
                        systemPrompt: effectiveSystemPrompt.isEmpty ? nil : effectiveSystemPrompt
                    )
                    for try await event in events {
                        if Task.isCancelled { break }
                        guard case .token(let token) = event else { continue }
                        buffer += token
                        flushPendingTokens(force: false)
                    }
                    flushPendingTokens(force: true)
                } else {
                    let stream = try await LLMService.shared.generate(
                        messages: messages,
                        videoURLs: videoURLs,
                        imageURLs: turnImageURLs,
                        systemPrompt: effectiveSystemPrompt.isEmpty ? nil : effectiveSystemPrompt,
                        temperature: conversation.temperature
                    )
                    for await token in stream {
                        buffer += token
                        flushPendingTokens(force: false)
                    }
                    flushPendingTokens(force: true)
                }

                // Even in Chat mode a model can echo tool-invocation syntax
                // or raw tool ids it was told about; none of that may be
                // persisted as the visible reply. (The render layer
                // sanitizes again, so the live stream was already clean.)
                assistantMessage.content = ToolInvocationSanitizer.displayText(
                    for: assistantMessage.content,
                    knownToolIDs: ToolsRegistry.shared.allToolIDs
                )

                // Auto-read only if the setting is enabled — and read the
                // answer, not the model's <thinking> reasoning.
                if UserDefaults.standard.bool(forKey: "autoReadAloud") {
                    let spoken = ThinkingContentParser.visibleContent(of: assistantMessage.content)
                    TTSService.shared.speak(text: spoken.isEmpty ? assistantMessage.content : spoken, messageID: assistantMessage.id)
                }

                conversation.updatedAt = .now
                try? context.save()
                AccessibilityNotification.Announcement("Response complete").post()
            } catch {
                if !Task.isCancelled {
                    assistantMessage.content += "\n\n[Error: \(error.localizedDescription)]"
                }
            }

            isGenerating = false
        }
    }

    private func generateAgentResponse(for conversation: Conversation, assistantMessage: Message, in context: ModelContext) async {
        liveToolCalls = []
        let userPrompt = conversation.sortedMessages.last(where: { $0.role == .user })?.content ?? ""
        let knownToolIDs = ToolsRegistry.shared.allToolIDs

        // The selected Agent Project scopes the whole run: its folder is
        // the workspace root every tool resolves against, and its notes,
        // instructions, and per-project memory go into the context.
        let project = AgentProjectsStore.shared.activeProject
        let projectContext = project.map { AgentProjectsStore.shared.contextBlock(for: $0) }

        // The harness adds the retrieved tool schemas itself; what it
        // never received before — and why Agent mode also claimed to
        // have no custom prompt and no skills — is everything assembled
        // here from the context index: the retrieved excerpts for this
        // prompt (custom-prompt chunks, skill excerpts, asset summaries,
        // project memory), and the <thinking> format instruction. Tool
        // schemas are excluded from this bundle
        // (includeToolSchemas: false) because the harness adds its own
        // retrieved set — the model never pays for the same schema twice,
        // and the Foundation-model runner gets its schemas natively.
        //
        // The directory is deliberately NOT included here: the harness
        // (MLX loop) and the Foundation-model runner each add the
        // counts-only directory to the final prompt themselves, so it
        // appears exactly once per prompt — carrying it in this
        // additional prompt as well made every Agent prompt pay for it
        // twice.
        let globalPrompt = UserDefaults.standard.string(forKey: "customSystemPrompt") ?? ""
        let conversationPrompt = conversation.systemPrompt ?? ""
        let agentIntent = ConversationRouter.intent(for: userPrompt)
        let agentContextPrompt = ModelContextBuilder.build(
            ModelContextBuilder.Input(
                isAgentMode: true,
                intent: agentIntent,
                indexDirectory: "",
                retrievedContext: ContextIndexManager.retrievedBundle(
                    query: userPrompt,
                    mode: .agent,
                    globalCustomPrompt: globalPrompt,
                    conversationCustomPrompt: conversationPrompt,
                    activeSkillIDs: Set(activeSkills.map(\.id)),
                    project: project,
                    includeToolSchemas: false,
                    intent: agentIntent
                ),
                thinkingEnabled: ThinkingSettings.isEnabled,
                thinkingBudget: ThinkingSettings.budget,
                modelDisplayName: displayName(for: selectedModelID),
                projectContext: projectContext
            )
        )

        // Raw streamed tokens are accumulated privately and only the
        // sanitized display text is ever written into the message: a tool
        // turn's tokens contain the raw invocation JSON, which belongs to
        // the tool cards, never to the message bubble.
        var rawStreamed = ""
        let outcome = await AntigravityAgentHarness.shared.run(
            prompt: userPrompt,
            modelID: selectedModelID,
            workspaceRoot: project?.rootURL ?? URL.documentsDirectory,
            projectID: project?.id,
            maxTurns: 10,
            backend: selectedBackend,
            additionalSystemPrompt: agentContextPrompt
        ) { [weak self] event in
            guard let self else { return }
            switch event {
            case .toolCallDetected(let tool, let arguments):
                // A new tool turn begins: the previous turn's streamed
                // prose was intermediate activity for a turn the loop
                // consumed, not final-answer text. Reset the stream
                // accumulator so intermediate turns never accumulate
                // into the visible bubble across turns (the outcome's
                // answer overwrites the bubble at the end regardless).
                rawStreamed = ""
                assistantMessage.content = ""
                var strArgs: [String: String] = [:]
                for (k, v) in arguments {
                    strArgs[k] = "\(v)"
                }
                let record = ToolCallRecord(toolID: tool, arguments: strArgs, status: .running)
                self.liveToolCalls.append(record)
            case .toolExecutionFinished(let tool, let result):
                if let index = self.liveToolCalls.lastIndex(where: { $0.toolID == tool && $0.status == .running }) {
                    var updated = self.liveToolCalls[index]
                    updated.status = result.success ? .completed : .failed(result.error ?? "Failed")
                    updated.result = result.output
                    updated.completedAt = .now
                    self.liveToolCalls[index] = updated
                }
            case .tokenStreamed(let token):
                rawStreamed += token
                assistantMessage.content = ToolInvocationSanitizer.displayText(for: rawStreamed, knownToolIDs: knownToolIDs)
            case .failed(let err):
                assistantMessage.content += "\n\n[Agent Error: \(err)]"
            default:
                break
            }
        }

        // The outcome's answer is authoritative (and already cleaned by the
        // loop engine); sanitize once more here so no path can persist a
        // raw invocation or tool id into the saved conversation.
        let sanitizedAnswer = ToolInvocationSanitizer.displayText(for: outcome.answer, knownToolIDs: knownToolIDs)
        // The run's reasoning is persisted back inside <thinking> tags —
        // the same storage form Chat mode uses — so the message row splits
        // it into ThinkingModelUI instead of the answer bubble. (The
        // session note below keeps using the answer alone.)
        let thinkingPrefix = outcome.thinking.map { "<thinking>\n\($0)\n</thinking>\n\n" } ?? ""
        if !sanitizedAnswer.isEmpty {
            assistantMessage.content = thinkingPrefix + sanitizedAnswer
        } else if assistantMessage.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            assistantMessage.content = thinkingPrefix + sanitizedAnswer
        }

        // Per-project memory: every run in a project leaves a session note
        // (task + outcome), so the next session in this project starts from
        // what happened here — in addition to any facts the agent itself
        // recorded with the project memory tool during the run.
        if let project {
            let taskSummary = String(userPrompt.prefix(160))
            let outcomeSummary = sanitizedAnswer.isEmpty
                ? (outcome.success ? "Completed without a written answer." : "Did not complete.")
                : String(sanitizedAnswer.prefix(200))
            AgentProjectsStore.shared.addMemoryEntry(
                projectID: project.id,
                text: "Task: \(taskSummary) — \(outcome.success ? "Outcome" : "Result (incomplete)"): \(outcomeSummary)",
                kind: .session
            )
        }

        let stepRecords: [ToolCallRecord] = outcome.steps
            .filter { $0.kind == .toolCall || $0.kind == .toolResult }
            .map { ToolCallRecord(agentStep: $0) }

        let finalRecords = !stepRecords.isEmpty ? stepRecords : self.liveToolCalls
        self.messageToolCalls[assistantMessage.id] = finalRecords
        self.liveToolCalls = []

        conversation.updatedAt = .now
        try? context.save()
        self.isGenerating = false
    }

    func stopGenerating() {
        generationTask?.cancel()
        generationTask = nil
        if isAgentMode {
            AntigravityAgentHarness.shared.cancel()
            liveToolCalls = []
        }
        isGenerating = false
    }

    @discardableResult
    func createConversation(in context: ModelContext) -> Conversation {
        let conversation = Conversation()
        context.insert(conversation)
        try? context.save()
        selectedConversation = conversation
        Task { await LLMService.shared.resetSession() }
        return conversation
    }

    func deleteConversation(_ conversation: Conversation, in context: ModelContext) {
        if selectedConversation?.id == conversation.id {
            selectedConversation = nil
        }
        context.delete(conversation)
        try? context.save()
    }

    func loadHFModel(_ model: HFModel) {
        loadTask?.cancel()
        selectedModelID = model.id
        selectedModelIsVisual = model.category == .video || model.category == .vision
        modelState = .downloading(0)
        lastAnnouncedMilestone = 0

        loadTask = Task {
            do {
                // Download first, through the real downloader, unless a complete
                // validated copy is already on disk. Loading a partial artifact
                // was the original bug.
                if !model.isDownloaded {
                    _ = try await ModelDownloadService.shared.download(modelID: model.id) { progress in
                        Task { @MainActor in
                            self.modelState = .downloading(progress.fractionCompleted)
                            self.announceProgressMilestone(progress.fractionCompleted)
                        }
                    }
                    self.scanInstalledModels()
                }
                let isVisual = model.category == .video || model.category == .vision
                modelState = .loading
                let stream = try await LLMService.shared.loadModelByID(
                    model.id,
                    isVideoModel: isVisual
                )
                for try await _ in stream { }
                try await LLMService.shared.finishLoading()
                modelState = .ready(model.displayName)
                AccessibilityNotification.Announcement("Model ready to use").post()
            } catch {
                let log = "[\(Date().formatted(date: .abbreviated, time: .standard))] Error loading \(model.id): \(error.localizedDescription)"
                self.downloadErrors[model.id] = log
                print("❌ [Locally Model Error] \(log)")
                modelState = .error(friendlyErrorMessage(for: error, model: model))
            }
        }
    }

    private func announceProgressMilestone(_ progress: Double) {
        let percent = Int(progress * 100)
        let milestones = [25, 50, 75]
        for milestone in milestones {
            if percent >= milestone && lastAnnouncedMilestone < milestone {
                lastAnnouncedMilestone = milestone
                AccessibilityNotification.Announcement("Download \(milestone) percent complete").post()
            }
        }
    }

    func friendlyErrorMessage(for error: Error, model: HFModel) -> String {
        let description = error.localizedDescription.lowercased()

        if description.contains("401") || description.contains("unauthorized") || description.contains("gated") {
            return "\(model.displayName) is gated or restricted on Hugging Face. Requires authentication or license approval."
        } else if description.contains("404") || description.contains("not found") {
            return "\(model.displayName) repository was not found on Hugging Face (404)."
        } else if description.contains("memory") || description.contains("ram") {
            return "This model is too large for your Mac's memory. Try a smaller model."
        } else if description.contains("network") || description.contains("internet") || description.contains("connection") {
            return "Could not download the model. Check your internet connection and try again."
        } else if description.contains("disk") || description.contains("space") || description.contains("storage") {
            return "Not enough storage space to download this model. Free up some disk space and try again."
        } else if description.contains("token") || description.contains("vocab") {
            return "This model's format is not supported yet. Try a different model."
        } else {
            return "Could not load \(model.displayName): \(error.localizedDescription)"
        }
    }

    // MARK: - Conversation management (feature G)

    func renameConversation(_ conversation: Conversation, to newTitle: String, in context: ModelContext) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        conversation.title = trimmed
        conversation.updatedAt = .now
        try? context.save()
    }

    func setConversationArchived(_ conversation: Conversation, archived: Bool, in context: ModelContext) {
        conversation.isArchived = archived
        try? context.save()
    }

    /// Creates a new conversation containing copies of the original's messages
    /// up to (and including) `message`. The original is left untouched, and
    /// the branch may switch models independently.
    @discardableResult
    func branchConversation(from conversation: Conversation, through message: Message, in context: ModelContext) -> Conversation {
        let branch = Conversation(title: conversation.title + " (branch)", modelIdentifier: conversation.modelIdentifier)
        branch.systemPrompt = conversation.systemPrompt
        branch.temperature = conversation.temperature
        branch.parentConversationID = conversation.id
        context.insert(branch)
        for original in conversation.sortedMessages {
            let copy = Message(role: original.role, content: original.content)
            copy.timestamp = original.timestamp
            copy.imageFileNames = original.imageFileNames
            copy.conversation = branch
            branch.messages.append(copy)
            if original.id == message.id { break }
        }
        try? context.save()
        selectedConversation = branch
        return branch
    }

    /// Regenerates the response to the last user message: the previous
    /// assistant reply is removed and a fresh one is generated in its place.
    func regenerateLastResponse(in context: ModelContext) {
        guard let conversation = selectedConversation, !isGenerating else { return }
        let sorted = conversation.sortedMessages
        guard let lastUserIndex = sorted.lastIndex(where: { $0.role == .user }) else { return }
        for message in sorted[(lastUserIndex + 1)...] {
            conversation.messages.removeAll { $0.id == message.id }
            context.delete(message)
        }
        try? context.save()
        generateResponse(for: conversation, in: context)
    }

    /// Edits a user message, discards everything after it, and regenerates —
    /// the classic edit-and-resend flow. The discarded tail is removed only
    /// from this conversation.
    func editUserMessage(_ message: Message, newContent: String, in context: ModelContext) {
        guard let conversation = message.conversation, !isGenerating else { return }
        let trimmed = newContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        message.content = trimmed
        let sorted = conversation.sortedMessages
        if let index = sorted.firstIndex(where: { $0.id == message.id }) {
            for later in sorted[(index + 1)...] {
                conversation.messages.removeAll { $0.id == later.id }
                context.delete(later)
            }
        }
        conversation.updatedAt = .now
        try? context.save()
        generateResponse(for: conversation, in: context)
    }

    // MARK: - Image attachment storage

    static var attachmentsDirectory: URL {
        JSONFileStore.directory.appendingPathComponent("Attachments")
    }

    /// Copies an attached image into app storage so the turn (and its vision
    /// context) survives relaunch. Returns the stored file name.
    static func persistImageAttachment(_ url: URL) -> String? {
        do {
            try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
            let name = "\(UUID().uuidString).\(url.pathExtension.isEmpty ? "png" : url.pathExtension)"
            let destination = attachmentsDirectory.appendingPathComponent(name)
            if url != destination {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: url, to: destination)
            }
            return name
        } catch {
            print("❌ [Locally] Could not store image attachment: \(error.localizedDescription)")
            return nil
        }
    }

    func scanInstalledModels() {
        var found: [InstalledModel] = []
        for modelId in HFHubCache.cachedModelIDs() {
            let parts = modelId.split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let author = String(parts[0])
            let modelName = String(parts[1])

            // Only *complete* models count as installed. A partial download
            // (missing shards / tokenizer / config) must never reach the loader.
            guard ModelArtifactValidator.isInstalled(modelID: modelId) else { continue }

            // Skip models that cannot be used for chat (TTS, transcription, embedding, etc.)
            guard !Self.looksLikeNonChatModel(modelName) else { continue }

            found.append(InstalledModel(id: modelId, displayName: modelName, author: author, isVisual: Self.looksLikeVisualModel(modelName)))
        }

        installedModels = found.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }

        // Default to the built-in Apple model when nothing is downloaded, and
        // only when the user has not already chosen a model.
        if selectedModelID == nil, installedModels.isEmpty, AppleFoundationModel.isAvailable {
            selectAppleModel()
        }
    }

    /// Renders the app's conversation turns as one self-contained prompt for
    /// engines whose chat state does not persist between calls (the Apple model).
    private static func transcript(
        from messages: [(role: String, content: String)],
        skipping skippedSystemPrompt: String?
    ) -> String {
        var lines: [String] = []
        for message in messages {
            switch message.role {
            case "user":
                lines.append("User: \(message.content)")
            case "assistant":
                // Reasoning (<thinking> blocks) is not re-sent as history.
                lines.append("Assistant: \(ThinkingContentParser.visibleContent(of: message.content))")
            case "system":
                // The conversation's system prompt already travels as the
                // session instructions; other system turns (the running
                // summary) are real context and must stay.
                if let skippedSystemPrompt, message.content == skippedSystemPrompt { continue }
                lines.append("System: \(message.content)")
            default:
                lines.append("\(message.role.capitalized): \(message.content)")
            }
        }
        lines.append("Assistant:")
        return lines.joined(separator: "\n\n")
    }

    func loadInstalledModel(_ model: InstalledModel) {
        if AppleFoundationModel.isAppleModel(model.id) {
            selectAppleModel()
            return
        }

        let pipeline: String? = model.isVisual ? "image-text-to-text" : nil
        let tags: [String] = model.isVisual ? ["image-text-to-text"] : []
        let hfModel = HFModel(
            id: model.id,
            name: model.id,
            downloads: 0,
            likes: 0,
            tags: tags,
            pipelineTag: pipeline,
            createdAt: nil
        )
        loadHFModel(hfModel)
    }

    /// Downloads a model *without* loading it into memory, using the real
    /// `ModelDownloadService`: full repo manifest, every file (all weight
    /// shards, config, tokenizer), resumable + retried transfers, and
    /// size/SHA-256 validation. The model is only reported downloaded after
    /// `ModelArtifactValidator` confirms the artifact is complete — a failed
    /// or interrupted download stays *not downloaded*.
    func downloadHFModel(_ model: HFModel) {
        downloadTask?.cancel()
        selectedModelID = model.id
        selectedModelIsVisual = model.category == .video || model.category == .vision
        modelState = .downloading(0)
        lastAnnouncedMilestone = 0
        downloadErrors[model.id] = nil

        downloadTask = Task {
            do {
                _ = try await ModelDownloadService.shared.download(modelID: model.id) { progress in
                    Task { @MainActor in
                        self.modelState = .downloading(progress.fractionCompleted)
                        self.announceProgressMilestone(progress.fractionCompleted)
                    }
                }
                modelState = .idle
                scanInstalledModels()
                AccessibilityNotification.Announcement("Model downloaded successfully").post()
            } catch is CancellationError {
                modelState = .idle
            } catch {
                let log = "[\(Date().formatted(date: .abbreviated, time: .standard))] Error downloading \(model.id): \(error.localizedDescription)"
                self.downloadErrors[model.id] = log
                print("❌ [Locally Model Error] \(log)")
                modelState = .error(friendlyErrorMessage(for: error, model: model))
            }
        }
    }

    /// Cancels the in-flight model download, if any. Already-downloaded files
    /// and resume data are kept, so a later download resumes instead of
    /// restarting — but the model is *not* marked installed.
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        if let id = selectedModelID {
            Task { await ModelDownloadService.shared.cancel(modelID: id) }
        }
        modelState = .idle
    }

    /// Heuristic to detect models that cannot be used for chat (TTS, transcription, embedding, audio, translation).
    static func looksLikeNonChatModel(_ name: String) -> Bool {
        let lower = name.lowercased()

        // TTS
        if lower.contains("tts") || lower.contains("kokoro") || lower.contains("orpheus")
            || lower.contains("parler") || lower.contains("bark") || lower.contains("outetts")
            || lower.contains("mars5") || lower.contains("styletts") || lower.contains("f5-tts")
            || lower.contains("cosyvoice") || lower.contains("chattts") || lower.contains("soprano")
            || lower.contains("vibevoice") || lower.contains("pocket-tts") || lower.contains("vyvo")
            || lower.contains("marvis") {
            return true
        }

        // Transcription / ASR
        if lower.contains("whisper") || lower.contains("wav2vec") || lower.contains("hubert")
            || lower.contains("conformer") || lower.contains("mms-") || lower.contains("parakeet") {
            return true
        }

        // Embedding
        if lower.contains("embedding") || lower.contains("gte-") || lower.contains("bge-")
            || lower.contains("nomic-embed") || lower.contains("e5-") || lower.contains("jina-embed") {
            return true
        }

        // Translation
        if lower.contains("nllb") || lower.contains("opus-mt") || lower.contains("marian")
            || lower.contains("madlad") {
            return true
        }

        // Audio processing
        if lower.contains("encodec") || lower.contains("musicgen") || lower.contains("audiogen")
            || lower.contains("audiocraft") || lower.contains("dac-") {
            return true
        }

        // Image generation (diffusion models)
        if lower.contains("stable-diffusion") || lower.contains("flux") || lower.contains("diffusion") {
            return true
        }

        return false
    }

    /// Heuristic to detect video or vision models from their name in the HF cache.
    /// Both video and vision models use the VLM pipeline.
    static func looksLikeVisualModel(_ name: String) -> Bool {
        let lower = name.lowercased()
        // Video patterns
        if lower.contains("video") || lower.contains("videollama") || lower.contains("videochat") {
            return true
        }
        // Vision patterns — mirrors HFModel.category detection
        if lower.contains("vision") || lower.contains("llava") || lower.contains("pixtral")
            || lower.contains("idefics") || lower.contains("minicpm-o")
            || lower.contains("paligemma") || lower.contains("florence")
            || lower.contains("molmo") || lower.contains("got-ocr")
            || lower.contains("moondream") || lower.contains("bunny")
            || lower.contains("internvl") || lower.contains("smolvlm")
            || lower.contains("fastvlm") {
            return true
        }
        // "VL" suffix/segment (e.g. Qwen2.5-VL, Phi-3.5-VL)
        if lower.hasSuffix("-vl") || lower.contains("-vl-") {
            return true
        }
        return false
    }
}

struct InstalledModel: Identifiable, Hashable {
    let id: String
    let displayName: String
    let author: String
    let isVisual: Bool
    var isLoadable: Bool = true
}
