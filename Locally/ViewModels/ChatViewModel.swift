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

        // If a model is not yet loaded into memory, auto-load the current or first installed model
        if case .ready = modelState {
            // Already ready, continue
        } else {
            // Check if we have installed models
            if installedModels.isEmpty {
                scanInstalledModels()
            }

            let candidateModel: InstalledModel? = {
                if let sel = selectedModelID, let match = installedModels.first(where: { $0.id == sel }) {
                    return match
                }
                return installedModels.first
            }()

            guard let modelToLoad = candidateModel else {
                let warning = Message(role: .system, content: "No downloaded models found on this Mac. Please open the Downloads tab or Settings → Models to download a model.")
                warning.conversation = conversation
                conversation.messages.append(warning)
                try? context.save()
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
                        let rawSummary = try await LLMService.shared.summarize(prompt: summaryPrompt)
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

                var effectiveSystemPrompt = conversation.systemPrompt ?? ""

                // Inject Active Skills into System Prompt
                if !activeSkills.isEmpty {
                    let skillsContext = activeSkills.map { skill in
                        "### Active Skill: \(skill.name)\n\(skill.fullMarkdown)"
                    }.joined(separator: "\n\n")
                    effectiveSystemPrompt += "\n\n[Active Skills Instructions]:\n" + skillsContext
                }

                let isThinkingEnabled = UserDefaults.standard.bool(forKey: "enableThinkingMode")
                let thinkingBudget = UserDefaults.standard.string(forKey: "thinkingBudget") ?? "medium"
                if isThinkingEnabled {
                    let thinkingInstruction: String
                    switch thinkingBudget {
                    case "low":
                        thinkingInstruction = "\n\n[Reasoning]: Think briefly step-by-step before answering."
                    case "high":
                        thinkingInstruction = "\n\n[Reasoning]: Perform thorough, deep, and rigorous step-by-step chain-of-thought analysis before concluding."
                    default:
                        thinkingInstruction = "\n\n[Reasoning]: Think step-by-step and reason clearly through the problem."
                    }
                    effectiveSystemPrompt += thinkingInstruction
                }

                if let knowledge = pendingKnowledgeContext {
                    effectiveSystemPrompt += "\n\n[Relevant passages from the user's local knowledge base — cite them like [Title · passage N] when you use them]:\n" + knowledge
                    pendingKnowledgeContext = nil
                }

                // Re-attach this turn's images (persisted copies) for vision models.
                let lastUserMessage = conversation.sortedMessages.last(where: { $0.role == .user })
                let turnImageURLs: [URL] = (lastUserMessage?.imageFileNames ?? []).map {
                    Self.attachmentsDirectory.appendingPathComponent($0)
                }

                let stream = try await LLMService.shared.generate(
                    messages: messages,
                    videoURLs: videoURLs,
                    imageURLs: turnImageURLs,
                    systemPrompt: effectiveSystemPrompt.isEmpty ? nil : effectiveSystemPrompt,
                    temperature: conversation.temperature
                )
                var buffer = ""
                var lastFlush = Date.now
                for await token in stream {
                    buffer += token
                    let now = Date.now
                    if now.timeIntervalSince(lastFlush) >= 0.08 {
                        assistantMessage.content += buffer
                        buffer = ""
                        lastFlush = now
                    }
                }
                if !buffer.isEmpty {
                    assistantMessage.content += buffer
                }

                // Auto-read only if the setting is enabled
                if UserDefaults.standard.bool(forKey: "autoReadAloud") {
                    TTSService.shared.speak(text: assistantMessage.content, messageID: assistantMessage.id)
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

    func stopGenerating() {
        generationTask?.cancel()
        generationTask = nil
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
    }

    func loadInstalledModel(_ model: InstalledModel) {
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
