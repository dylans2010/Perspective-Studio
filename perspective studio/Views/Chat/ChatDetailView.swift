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
    @Environment(\.openWindow) private var openWindow
    let conversation: Conversation
    @Bindable var chatViewModel: ChatViewModel
    var isSidebarCollapsed: Bool = false
    var onToggleSidebar: (() -> Void)? = nil
    var onOpenSettings: (() -> Void)? = nil

    @AppStorage("chatGradientTheme") private var gradientPresetRaw: String = GradientPreset.aurora.rawValue
    @AppStorage("chatGradientTopHex") private var customTopHex: String = GradientTheme.defaultTopHex
    @AppStorage("chatGradientBottomHex") private var customBottomHex: String = GradientTheme.defaultBottomHex
    @AppStorage("customSystemPrompt") private var globalSystemPrompt: String = ""
    @AppStorage("enableThinkingMode") private var enableThinkingMode: Bool = true
    @AppStorage("thinkingBudget") private var thinkingBudget: String = "medium"

    @State private var showSkillsPopover: Bool = false
    @FocusState private var isInputFocused: Bool

    private let suggestions: [ChatPromptSuggestion] = [
        ChatPromptSuggestion(action: "Decide", detail: "what to cook for dinner"),
        ChatPromptSuggestion(action: "Prepare", detail: "for a job interview"),
        ChatPromptSuggestion(action: "Identify", detail: "this landmark"),
        ChatPromptSuggestion(action: "Begin", detail: "meditating"),
        ChatPromptSuggestion(action: "Plan", detail: "a vacation itinerary"),
        ChatPromptSuggestion(action: "Boost", detail: "my productivity")
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
            // Full-window background gradient providing underlying color for Liquid Glass refraction
            LinearGradient(
                colors: activeGradientColors,
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top floating controls matching Image 1 & 2 (Level with traffic lights, Center Model Selector, Trailing New Chat)
                topControlBar

                // Main content: either welcome hero + suggestion cards or active message stream
                if isEmptyConversation {
                    emptyStateContent
                } else {
                    messageStreamContent
                }

                // Suggestion cards row using pure Liquid Glass
                if isEmptyConversation {
                    suggestionCardsRow
                        .padding(.bottom, 14)
                }

                // Bottom floating composer bar using pure Liquid Glass
                bottomComposerBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }
        }
        .onAppear {
            chatViewModel.scanInstalledModels()
            if (conversation.systemPrompt == nil || conversation.systemPrompt?.isEmpty == true) && !globalSystemPrompt.isEmpty {
                conversation.systemPrompt = globalSystemPrompt
            }
        }
    }

    // MARK: - Top Control Bar (Exact Image 1 Parity)

    private var topControlBar: some View {
        ZStack(alignment: .center) {
            // Center element is mathematically centered in the entire view width
            modelSelectorPill

            // Leading and Trailing items leveled horizontally in the same 32pt row
            HStack(alignment: .center, spacing: 10) {
                if isSidebarCollapsed {
                    // Traffic lights safe spacing
                    Spacer()
                        .frame(width: 76)

                    Button {
                        openWindow(id: "settings")
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 28, height: 28)
                            .liquidGlass(.circle)
                    }
                    .buttonStyle(.plain)
                    .help("Settings (⌘,)")
                }

                Spacer()

                Button {
                    createNewChat()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 28, height: 28)
                        .liquidGlass(.circle)
                }
                .buttonStyle(.plain)
                .help("New Chat (⌘N)")
            }
        }
        .frame(height: 32)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    // MARK: - Model Selector Pill (Pure Liquid Glass)

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
            HStack(spacing: 6) {
                Text(currentModelTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .liquidGlass(.capsule)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Empty State (Hero)

    private var emptyStateContent: some View {
        VStack(spacing: 16) {
            Spacer()

            Text("Meet the new Apple Foundation")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 3)

            Text("Use Apple’s latest on-device foundation model — with better answers, improved instruction-following, and image understanding.")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.white.opacity(0.82))
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
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
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

    // MARK: - Suggestion Cards Row (Pure Liquid Glass)

    private var suggestionCardsRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
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
                                .foregroundStyle(.white.opacity(0.72))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .liquidGlass(.rect(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Bottom Floating Composer Bar (Pure Liquid Glass)

    private var bottomComposerBar: some View {
        VStack(spacing: 8) {
            // Attachments pill list
            if !chatViewModel.attachedFileURLs.isEmpty || chatViewModel.attachedVideoURL != nil {
                attachmentsRow
            }

            HStack(spacing: 10) {
                // Left '+' Attachment Button in Liquid Glass
                Button {
                    pickAttachments()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .liquidGlass(.circle)
                }
                .buttonStyle(.plain)
                .help("Attach Files or Media")

                // Left Lightbulb: Controls Model Thinking / Reasoning Mode
                Menu {
                    Toggle("Enable Thinking Mode", isOn: $enableThinkingMode)

                    Divider()

                    Section("Reasoning Effort") {
                        Button {
                            thinkingBudget = "low"
                            enableThinkingMode = true
                        } label: {
                            HStack {
                                Text("Low (Quick Analysis)")
                                if thinkingBudget == "low" && enableThinkingMode {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }

                        Button {
                            thinkingBudget = "medium"
                            enableThinkingMode = true
                        } label: {
                            HStack {
                                Text("Medium (Balanced)")
                                if thinkingBudget == "medium" && enableThinkingMode {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }

                        Button {
                            thinkingBudget = "high"
                            enableThinkingMode = true
                        } label: {
                            HStack {
                                Text("High (Deep Reasoning)")
                                if thinkingBudget == "high" && enableThinkingMode {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: enableThinkingMode ? "lightbulb.fill" : "lightbulb")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(enableThinkingMode ? Color.yellow : Color.white.opacity(0.85))
                        .frame(width: 44, height: 44)
                        .liquidGlass(.circle)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(enableThinkingMode ? "Thinking Mode: Active (\(thinkingBudget.capitalized))" : "Thinking Mode: Off")

                // Left Sparkles: Chat Skills Integration
                Button {
                    showSkillsPopover.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: chatViewModel.activeSkills.isEmpty ? "sparkles" : "sparkles.rectangle.stack.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(chatViewModel.activeSkills.isEmpty ? Color.white.opacity(0.85) : Color.cyan)
                        if !chatViewModel.activeSkills.isEmpty {
                            Text("\(chatViewModel.activeSkills.count)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.cyan)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .liquidGlass(.circle)
                }
                .buttonStyle(.plain)
                .help("Active Skills (\(chatViewModel.activeSkills.count) active in chat)")
                .popover(isPresented: $showSkillsPopover) {
                    ActiveSkillsPopoverView(chatViewModel: chatViewModel)
                }

                // Main Input Capsule in Pure Liquid Glass
                HStack(alignment: .center, spacing: 10) {
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
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
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
                                .foregroundStyle(canSend ? .white : .white.opacity(0.35))
                                .frame(width: 32, height: 32)
                                .background(canSend ? Color.white.opacity(0.28) : Color.white.opacity(0.12))
                                .clipShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSend)
                        .help("Send Message (Return)")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .frame(minHeight: 52)
                .liquidGlass(.capsule)
            }
        }
    }

    // MARK: - Attachments Row

    private var attachmentsRow: some View {
        ScrollView(.horizontal) {
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
        .scrollIndicators(.hidden)
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
                    .foregroundStyle(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .liquidGlass(.capsule)
    }

    // MARK: - Actions

    private var canSend: Bool {
        !chatViewModel.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chatViewModel.isGenerating
    }

    private func sendCurrentMessage() {
        guard canSend else { return }
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

// MARK: - Message Row View (Pure Liquid Glass)

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
                            .foregroundStyle(.white.opacity(0.95))
                        Text("Locally")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    } else {
                        Text("You")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    Text(message.timestamp, format: .dateTime.hour().minute())
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.6))
                }

                // Bubble using Liquid Glass
                Text(message.content)
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .liquidGlass(.rect(cornerRadius: 18), isClear: !isAssistant)

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
                            .foregroundStyle(.white.opacity(0.75))
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
                            .foregroundStyle(.white.opacity(0.75))
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

// MARK: - Active Skills Popover

struct ActiveSkillsPopoverView: View {
    @Bindable var chatViewModel: ChatViewModel
    @State private var skillsManager = SkillsManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.cyan)
                    Text("Chat Skills")
                        .font(.system(size: 14, weight: .bold))
                }
                Spacer()
                if !chatViewModel.activeSkills.isEmpty {
                    Button("Clear All") {
                        chatViewModel.activeSkills.removeAll()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Text("Enable skills to guide on-device AI responses with specialist workflows and prompt instructions.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Divider()

            if skillsManager.skills.isEmpty {
                VStack(spacing: 8) {
                    Text("No local skills discovered yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Scan Skills") {
                        Task { await skillsManager.scanAllSkills() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(skillsManager.skills) { skill in
                            let isActive = chatViewModel.isSkillActive(skill)
                            Button {
                                chatViewModel.toggleSkill(skill)
                            } label: {
                                HStack(alignment: .center, spacing: 10) {
                                    Image(systemName: skill.source.icon)
                                        .font(.system(size: 13))
                                        .foregroundStyle(skill.source.brandColor)
                                        .frame(width: 22)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(skill.name)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(.white)
                                        Text(skill.description)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.white.opacity(0.65))
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(isActive ? Color.cyan : Color.white.opacity(0.3))
                                        .font(.system(size: 14))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(isActive ? Color.cyan.opacity(0.18) : Color.white.opacity(0.05), in: .rect(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(Color(hex: "13171D") ?? .black)
    }
}
