import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AppKit

struct ChatPromptSuggestion: Identifiable {
    let id = UUID()
    let action: String
    let detail: String
    var fullPrompt: String {
        "\(action) \(detail)"
    }
}

struct ChatDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let conversation: Conversation
    @Bindable var chatViewModel: ChatViewModel
    var onToggleSidebar: (() -> Void)? = nil
    var onOpenSettings: (() -> Void)? = nil

    @AppStorage("chatGradientTheme") private var gradientPresetRaw: String = GradientPreset.aurora.rawValue
    @AppStorage("chatGradientTopHex") private var customTopHex: String = GradientTheme.defaultTopHex
    @AppStorage("chatGradientBottomHex") private var customBottomHex: String = GradientTheme.defaultBottomHex
    @AppStorage("customSystemPrompt") private var globalSystemPrompt: String = ""
    @AppStorage("enableThinkingMode") private var enableThinkingMode: Bool = false

    @State private var showingModelPicker = false
    @State private var showingQuickPrompts = false
    @State private var showingAttachmentPicker = false
    @FocusState private var isInputFocused: Bool

    private let suggestions: [ChatPromptSuggestion] = [
        ChatPromptSuggestion(action: "Tell me", detail: "something fascinating"),
        ChatPromptSuggestion(action: "Boost", detail: "my productivity"),
        ChatPromptSuggestion(action: "Prepare", detail: "for a first date"),
        ChatPromptSuggestion(action: "Plan", detail: "a movie night"),
        ChatPromptSuggestion(action: "Begin", detail: "meditating"),
        ChatPromptSuggestion(action: "Decide", detail: "what to cook for dinner"),
        ChatPromptSuggestion(action: "Master", detail: "smartphone photography"),
        ChatPromptSuggestion(action: "Practice", detail: "a new language"),
        ChatPromptSuggestion(action: "Analyze", detail: "a complex problem"),
        ChatPromptSuggestion(action: "Draft", detail: "a professional email")
    ]

    private var activeGradientColors: [Color] {
        GradientTheme.activeColors(
            presetRaw: gradientPresetRaw,
            customTopHex: customTopHex,
            customBottomHex: customBottomHex
        )
    }

    private var sortedMessages: [Message] {
        conversation.sortedMessages
    }

    private var isEmptyConversation: Bool {
        sortedMessages.isEmpty
    }

    private var currentModelTitle: String {
        if let id = chatViewModel.selectedModelID {
            if let installed = chatViewModel.installedModels.first(where: { $0.id == id }) {
                return installed.displayName
            }
            return id.replacingOccurrences(of: "mlx-community/", with: "")
        }
        return "Gemma 4 QAT E4B"
    }

    var body: some View {
        ZStack {
            // Full-window background gradient matching the mockup
            LinearGradient(
                colors: activeGradientColors,
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top control bar
                topNavigationBar

                // Main content: either the welcome hero + suggestion cards or active message stream
                if isEmptyConversation {
                    emptyStateContent
                } else {
                    messageStreamContent
                }

                // Suggestion pills row (shown on empty conversation, or when composer is focused)
                if isEmptyConversation {
                    suggestionCardsRow
                        .padding(.bottom, 12)
                }

                // Bottom floating composer bar
                bottomComposerBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }
        }
        .onAppear {
            chatViewModel.scanInstalledModels()
            // If conversation has no custom system prompt but global exists, copy it
            if (conversation.systemPrompt == nil || conversation.systemPrompt?.isEmpty == true) && !globalSystemPrompt.isEmpty {
                conversation.systemPrompt = globalSystemPrompt
            }
        }
    }

    // MARK: - Top Navigation Bar

    private var topNavigationBar: some View {
        HStack(spacing: 12) {
            // Left Controls: Settings button + Sidebar toggle button
            HStack(spacing: 10) {
                Button {
                    onOpenSettings?()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 28, height: 28)
                        .background(.ultraThinMaterial.opacity(0.4))
                        .clipShape(.circle)
                        .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Settings")

                Button {
                    onToggleSidebar?()
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 32, height: 28)
                        .background(.ultraThinMaterial.opacity(0.4))
                        .clipShape(.rect(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Toggle Sidebar")
            }

            Spacer()

            // Center: Model Selector Pill
            modelSelectorPill

            Spacer()

            // Right: New Chat Compose Button
            Button {
                createNewChat()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial.opacity(0.4))
                    .clipShape(.rect(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.12), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("New Chat (⌘N)")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Model Selector Pill

    private var modelSelectorPill: some View {
        Menu {
            Section("Current Model") {
                Text(currentModelTitle)
            }

            if !chatViewModel.installedModels.isEmpty {
                Section("Installed Models") {
                    ForEach(chatViewModel.installedModels) { model in
                        Button {
                            chatViewModel.loadInstalledModel(model)
                        } label: {
                            HStack {
                                Text(model.displayName)
                                if model.id == chatViewModel.selectedModelID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            } else {
                Section {
                    Text("No downloaded models. Visit Downloads tab to get models.")
                }
            }

            Divider()

            Button("Refresh Models") {
                chatViewModel.scanInstalledModels()
            }
        } label: {
            HStack(spacing: 5) {
                Text(currentModelTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.25))
            .clipShape(.capsule)
            .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 0.8))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Empty State (Hero)

    private var emptyStateContent: some View {
        VStack(spacing: 16) {
            Spacer()

            Text("Meet the new Apple Foundation")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 2)

            Text("Use Apple’s latest on-device foundation model — with better answers, improved instruction-following, and image understanding.")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.white.opacity(0.78))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
                .lineSpacing(3)

            Spacer()
        }
        .padding(.horizontal, 24)
        .transition(.opacity)
    }

    // MARK: - Message Stream

    private var messageStreamContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(sortedMessages) { message in
                        MessageRowView(message: message)
                            .id(message.id)
                    }

                    if chatViewModel.isGenerating {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Thinking & Generating...")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .onChange(of: conversation.messages.count) {
                if let lastID = sortedMessages.last?.id {
                    if reduceMotion {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    } else {
                        withAnimation {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Suggestion Cards Row

    private var suggestionCardsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(suggestions) { item in
                    Button {
                        applySuggestion(item)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.action)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)

                            Text(item.detail)
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(.white.opacity(0.65))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.38))
                        .clipShape(.rect(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(.white.opacity(0.08), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Bottom Floating Composer Bar

    private var bottomComposerBar: some View {
        VStack(spacing: 8) {
            // Display attachments if present
            if !chatViewModel.attachedFileURLs.isEmpty || chatViewModel.attachedVideoURL != nil {
                attachmentsRow
            }

            HStack(spacing: 10) {
                // Left '+' Attachment Button
                Button {
                    pickAttachments()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.black.opacity(0.38))
                        .clipShape(.circle)
                        .overlay(Circle().stroke(.white.opacity(0.08), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Attach Files or Images")

                // Left Lightbulb Brainstorm / Modes Button
                Menu {
                    Button("Brainstorm Ideas") {
                        chatViewModel.messageText = "Brainstorm 5 innovative ideas for: "
                        isInputFocused = true
                    }
                    Button("Explain Simply") {
                        chatViewModel.messageText = "Explain like I'm 12: "
                        isInputFocused = true
                    }
                    Button("Code Review & Refactor") {
                        chatViewModel.messageText = "Review and refactor the following code:\n```\n\n```"
                        isInputFocused = true
                    }
                    Button("Step-by-Step Reasoning") {
                        chatViewModel.messageText = "Think step-by-step and solve: "
                        isInputFocused = true
                    }
                } label: {
                    Image(systemName: "lightbulb")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.black.opacity(0.38))
                        .clipShape(.circle)
                        .overlay(Circle().stroke(.white.opacity(0.08), lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Suggested Modes & Prompts")

                // Main Rounded Input Capsule
                HStack(spacing: 8) {
                    TextField("Ask anything", text: $chatViewModel.messageText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .focused($isInputFocused)
                        .onSubmit {
                            sendCurrentMessage()
                        }

                    // Send or Stop Button
                    if chatViewModel.isGenerating {
                        Button {
                            chatViewModel.stopGenerating()
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(Color.red.opacity(0.85))
                                .clipShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .help("Stop Generating")
                    } else {
                        Button {
                            sendCurrentMessage()
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(canSend ? .black : .white.opacity(0.4))
                                .frame(width: 30, height: 30)
                                .background(canSend ? Color.white : Color.white.opacity(0.18))
                                .clipShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSend)
                        .help("Send Message (Return)")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(minHeight: 46)
                .background(Color.black.opacity(0.42))
                .clipShape(.rect(cornerRadius: 23))
                .overlay(
                    RoundedRectangle(cornerRadius: 23)
                        .stroke(.white.opacity(0.10), lineWidth: 1)
                )
            }
        }
    }

    // MARK: - Attachments Row

    private var attachmentsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let videoURL = chatViewModel.attachedVideoURL {
                    attachmentChip(name: videoURL.lastPathComponent, icon: "film") {
                        chatViewModel.attachedVideoURL = nil
                    }
                }
                ForEach(chatViewModel.attachedFileURLs, id: \.self) { url in
                    attachmentChip(name: url.lastPathComponent, icon: "doc.text") {
                        chatViewModel.attachedFileURLs.removeAll { $0 == url }
                    }
                }
            }
        }
    }

    private func attachmentChip(name: String, icon: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.white)

            Text(name)
                .font(.caption)
                .foregroundStyle(.white)
                .lineLimit(1)

            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.15))
        .clipShape(.capsule)
    }

    // MARK: - Actions

    private var canSend: Bool {
        !chatViewModel.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chatViewModel.isGenerating
    }

    private func sendCurrentMessage() {
        guard canSend else { return }

        // If thinking mode is enabled, prepend a subtle directive if not already included
        if enableThinkingMode && !chatViewModel.messageText.contains("Think step by step") {
            // The system prompt handles instructions, but we can ensure conversation settings are aligned
        }

        chatViewModel.sendMessage(in: modelContext)
    }

    private func applySuggestion(_ item: ChatPromptSuggestion) {
        chatViewModel.messageText = item.fullPrompt + " "
        isInputFocused = true
    }

    private func createNewChat() {
        chatViewModel.createConversation(in: modelContext)
    }

    private func pickAttachments() {
        let panel = NSOpenPanel()
        panel.title = "Attach Files or Media"
        panel.allowedContentTypes = [.item]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        if panel.runModal() == .OK {
            for url in panel.urls {
                let ext = url.pathExtension.lowercased()
                if ["mp4", "mov", "m4v", "avi", "mkv"].contains(ext) {
                    chatViewModel.attachedVideoURL = url
                } else if !chatViewModel.attachedFileURLs.contains(url) {
                    chatViewModel.attachedFileURLs.append(url)
                }
            }
        }
    }
}

// MARK: - Glassmorphic Message Row

private struct MessageRowView: View {
    let message: Message
    @State private var copied = false
    @State private var tts = TTSService.shared

    private var isAssistant: Bool {
        message.role == .assistant
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if !isAssistant {
                Spacer(minLength: 40)
            }

            VStack(alignment: isAssistant ? .leading : .trailing, spacing: 6) {
                // Header (role + time)
                HStack(spacing: 6) {
                    if isAssistant {
                        Image(systemName: "apple.intelligence")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                        Text("Locally")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    } else {
                        Text("You")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    Text(message.timestamp, format: .dateTime.hour().minute())
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                }

                // Bubble
                Text(message.content)
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        isAssistant
                            ? Color.black.opacity(0.35)
                            : Color.white.opacity(0.18)
                    )
                    .clipShape(.rect(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    )

                // Assistant action buttons (Copy & TTS)
                if isAssistant && !message.content.isEmpty {
                    HStack(spacing: 12) {
                        Button {
                            copyText(message.content)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                Text(copied ? "Copied" : "Copy")
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.7))
                        }
                        .buttonStyle(.plain)

                        Button {
                            if tts.speakingMessageID == message.id {
                                tts.stop()
                            } else {
                                tts.speak(text: message.content, messageID: message.id)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: tts.speakingMessageID == message.id ? "stop.circle.fill" : "speaker.wave.2")
                                Text(tts.speakingMessageID == message.id ? "Stop" : "Read Aloud")
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 2)
                    .padding(.leading, 4)
                }
            }

            if isAssistant {
                Spacer(minLength: 40)
            }
        }
    }

    private func copyText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { copied = false }
        }
    }
}
