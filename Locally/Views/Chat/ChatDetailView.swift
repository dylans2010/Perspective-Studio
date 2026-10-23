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
    @Environment(\.colorScheme) private var colorScheme
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
    @State private var editingMessage: Message?
    @State private var editedMessageText: String = ""
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
        chatViewModel.displayName(for: chatViewModel.selectedModelID) ?? "Select Model"
    }

    /// The built-in Apple model, when this Mac can offer it at all.
    private var appleModelChoice: InstalledModel? {
        chatViewModel.modelChoices.first { AppleFoundationModel.isAppleModel($0.id) }
    }

    var body: some View {
        ZStack {
            if isEmptyConversation {
                // Full-window background gradient providing underlying color for Liquid Glass refraction on hero
                LinearGradient(
                    colors: activeGradientColors,
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            } else {
                // Modern clean solid macOS background so content and typography are 100% crisp and readable.
                // In Agent mode the background takes a faint cyan cast — a
                // second, ambient signal of the mode alongside the banner.
                Group {
                    if chatViewModel.isAgentMode {
                        if colorScheme == .dark {
                            Color(red: 0.05, green: 0.10, blue: 0.12)
                        } else {
                            Color(red: 0.93, green: 0.97, blue: 0.98)
                        }
                    } else if colorScheme == .dark {
                        Color(red: 0.08, green: 0.085, blue: 0.10)
                    } else {
                        Color(red: 0.965, green: 0.969, blue: 0.976)
                    }
                }
                .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                // Top floating controls: Mode Selector + Model Selector + Actions
                topControlBar

                // Agent mode gets its own persistent banner, so the current
                // mode is never in doubt (previously only the small toggle
                // pill and the composer placeholder changed).
                if chatViewModel.isAgentMode {
                    AgentModeBannerView(chatViewModel: chatViewModel)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Main content: either welcome hero + suggestion cards or active message stream
                if isEmptyConversation {
                    emptyStateContent
                } else {
                    messageStreamContent
                }

                // Suggestion cards row
                if isEmptyConversation {
                    suggestionCardsRow
                        .padding(.bottom, 14)
                }

                // Bottom floating composer bar
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
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
        .onPasteCommand(of: [.image, .png, .jpeg]) { providers in
            _ = handleDrop(providers: providers)
        }
        .sheet(item: $editingMessage) { message in
            VStack(alignment: .leading, spacing: 12) {
                Text("Edit Message")
                    .font(.headline)
                Text("Editing discards the replies after this message and generates a new response.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $editedMessageText)
                    .frame(minHeight: 120)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { editingMessage = nil }
                    Button("Resend") {
                        chatViewModel.editUserMessage(message, newContent: editedMessageText, in: modelContext)
                        editingMessage = nil
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(width: 480)
        }
    }

    // MARK: - Top Control Bar

    private var topControlBar: some View {
        ZStack(alignment: .center) {
            // Center element: Mode Switcher (Chat vs Agent) + Model Selector Pill
            HStack(spacing: 8) {
                modeSelectorPill
                modelSelectorPill
                // Agent mode: the project picker — which folder (codebase)
                // the agent works in, with that project's own memory.
                if chatViewModel.isAgentMode {
                    AgentProjectPickerView(isEmptyConversation: isEmptyConversation)
                        .transition(.opacity)
                }
            }

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
                            .foregroundStyle(isEmptyConversation ? Color.white.opacity(0.85) : Color.secondary)
                            .frame(width: 28, height: 28)
                            .background(
                                isEmptyConversation ? Color.black.opacity(0.2) : Color.primary.opacity(0.06),
                                in: .circle
                            )
                            .overlay(
                                Circle()
                                    .stroke(isEmptyConversation ? Color.white.opacity(0.15) : Color.primary.opacity(0.1), lineWidth: 1)
                            )
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
                        .foregroundStyle(isEmptyConversation ? Color.white.opacity(0.85) : Color.secondary)
                        .frame(width: 28, height: 28)
                        .background(
                            isEmptyConversation ? Color.black.opacity(0.2) : Color.primary.opacity(0.06),
                            in: .circle
                        )
                        .overlay(
                            Circle()
                                .stroke(isEmptyConversation ? Color.white.opacity(0.15) : Color.primary.opacity(0.1), lineWidth: 1)
                        )
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

    // MARK: - Mode Selector Pill (Chat vs Agent)

    private var modeSelectorPill: some View {
        HStack(spacing: 2) {
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    chatViewModel.isAgentMode = false
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 10))
                    Text("Chat")
                        .font(.system(size: 12, weight: !chatViewModel.isAgentMode ? .bold : .medium))
                }
                .foregroundStyle(!chatViewModel.isAgentMode ? (isEmptyConversation ? .white : Color.primary) : (isEmptyConversation ? .white.opacity(0.6) : Color.secondary))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    !chatViewModel.isAgentMode
                        ? (isEmptyConversation ? Color.white.opacity(0.22) : Color.primary.opacity(0.12))
                        : Color.clear,
                    in: .capsule
                )
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    chatViewModel.isAgentMode = true
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .font(.system(size: 10, weight: .bold))
                    Text("Agent")
                        .font(.system(size: 12, weight: chatViewModel.isAgentMode ? .bold : .medium))
                }
                .foregroundStyle(chatViewModel.isAgentMode ? Color.cyan : (isEmptyConversation ? .white.opacity(0.6) : Color.secondary))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    chatViewModel.isAgentMode
                        ? Color.cyan.opacity(0.2)
                        : Color.clear,
                    in: .capsule
                )
            }
            .buttonStyle(.plain)
        }
        .padding(2)
        .background(
            isEmptyConversation
                ? Color.black.opacity(0.2)
                : (colorScheme == .dark ? Color(white: 0.14) : Color(white: 0.92)),
            in: .capsule
        )
        .overlay(
            Capsule()
                .stroke(
                    isEmptyConversation
                        ? Color.white.opacity(0.15)
                        : Color.primary.opacity(0.1),
                    lineWidth: 1
                )
        )
    }

    // MARK: - Model Selector Pill

    private var modelSelectorPill: some View {
        Menu {
            Section("Current Model") {
                Text(currentModelTitle)
            }

            if let appleModelChoice {
                Section("Built-in") {
                    Button {
                        chatViewModel.loadInstalledModel(appleModelChoice)
                    } label: {
                        HStack {
                            Text(appleModelChoice.displayName)
                            if let status = chatViewModel.appleModelAvailability.shortStatus {
                                Text(status)
                            }
                            if appleModelChoice.id == chatViewModel.selectedModelID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(!chatViewModel.appleModelAvailability.isAvailable)
                }
            }

            if !chatViewModel.installedModels.isEmpty {
                Section("Downloaded Models") {
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
                    Text("No downloaded models yet. The built-in model runs without a download.")
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
                    .foregroundStyle(isEmptyConversation ? .white : .primary)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isEmptyConversation ? .white.opacity(0.8) : .secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                isEmptyConversation
                    ? Color.black.opacity(0.2)
                    : (colorScheme == .dark ? Color(white: 0.14) : Color(white: 0.92)),
                in: .capsule
            )
            .overlay(
                Capsule()
                    .stroke(
                        isEmptyConversation
                            ? Color.white.opacity(0.15)
                            : Color.primary.opacity(0.1),
                        lineWidth: 1
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Empty State (Hero)

    private var emptyStateContent: some View {
        VStack(spacing: 16) {
            Spacer()

            if chatViewModel.isAgentMode {
                Image(systemName: "cpu.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.cyan)
                    .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 3)

                Text("Agent Mode")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 3)

                Text("This conversation runs as an autonomous agent: the model can call Locally's tools, consult its system assets, and work through multi-step tasks — inspecting files, searching your workspace, and reporting back. Switch to Chat above for a plain conversation with no tool execution.")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.white.opacity(0.82))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                    .lineSpacing(3)
            } else {
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
            }

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
                        MessageRowView(
                            message: message,
                            toolCalls: chatViewModel.messageToolCalls[message.id] ?? [],
                            isStreaming: chatViewModel.isGenerating && message.id == sortedMessages.last?.id,
                            onBranch: { chatViewModel.branchConversation(from: conversation, through: message, in: modelContext) },
                            onRegenerate: { chatViewModel.regenerateLastResponse(in: modelContext) },
                            onEdit: {
                                editingMessage = message
                                editedMessageText = message.content
                            }
                        )
                        .id(message.id)
                    }

                    // Live active tool calls during Agent turn
                    if chatViewModel.isGenerating && !chatViewModel.liveToolCalls.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(chatViewModel.liveToolCalls) { record in
                                ToolCallView(record: record)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 4)
                    }

                    if chatViewModel.isGenerating && chatViewModel.liveToolCalls.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(chatViewModel.isAgentMode ? "Agent reasoning & searching..." : "Thinking & Generating...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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

    // MARK: - Suggestion Cards Row

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

    // MARK: - Bottom Floating Composer Bar

    private var bottomComposerBar: some View {
        VStack(spacing: 8) {
            // Attachments pill list
            if !chatViewModel.attachedFileURLs.isEmpty || chatViewModel.attachedVideoURL != nil || !chatViewModel.attachedImageURLs.isEmpty {
                attachmentsRow
            }

            HStack(spacing: 10) {
                // Left '+' Attachment Button
                Button {
                    pickAttachments()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isEmptyConversation ? Color.white : Color.primary)
                        .frame(width: 44, height: 44)
                        .background(
                            isEmptyConversation
                                ? Color.black.opacity(0.2)
                                : (colorScheme == .dark ? Color(white: 0.14) : Color(white: 0.92)),
                            in: .circle
                        )
                        .overlay(
                            Circle()
                                .stroke(isEmptyConversation ? Color.white.opacity(0.15) : Color.primary.opacity(0.1), lineWidth: 1)
                        )
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
                        .foregroundStyle(enableThinkingMode ? Color.yellow : (isEmptyConversation ? Color.white.opacity(0.85) : Color.secondary))
                        .frame(width: 44, height: 44)
                        .background(
                            isEmptyConversation
                                ? Color.black.opacity(0.2)
                                : (colorScheme == .dark ? Color(white: 0.14) : Color(white: 0.92)),
                            in: .circle
                        )
                        .overlay(
                            Circle()
                                .stroke(isEmptyConversation ? Color.white.opacity(0.15) : Color.primary.opacity(0.1), lineWidth: 1)
                        )
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
                            .foregroundStyle(chatViewModel.activeSkills.isEmpty ? (isEmptyConversation ? Color.white.opacity(0.85) : Color.secondary) : Color.cyan)
                        if !chatViewModel.activeSkills.isEmpty {
                            Text("\(chatViewModel.activeSkills.count)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.cyan)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .background(
                        isEmptyConversation
                            ? Color.black.opacity(0.2)
                            : (colorScheme == .dark ? Color(white: 0.14) : Color(white: 0.92)),
                        in: .circle
                    )
                    .overlay(
                        Circle()
                            .stroke(isEmptyConversation ? Color.white.opacity(0.15) : Color.primary.opacity(0.1), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help("Active Skills (\(chatViewModel.activeSkills.count) active in chat)")
                .popover(isPresented: $showSkillsPopover) {
                    ActiveSkillsPopoverView(chatViewModel: chatViewModel)
                }

                // Main Input Capsule
                HStack(alignment: .center, spacing: 10) {
                    TextField(chatViewModel.isAgentMode ? "Ask Agent to inspect, code, or execute tools..." : "Ask anything", text: $chatViewModel.messageText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .font(.system(size: 14))
                        .foregroundStyle(isEmptyConversation ? Color.white : Color.primary)
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
                                .background(Color.red.opacity(0.85), in: .circle)
                        }
                        .buttonStyle(.plain)
                        .help("Stop Generating")
                    } else {
                        Button {
                            sendCurrentMessage()
                        } label: {
                            Image(systemName: chatViewModel.isAgentMode ? "bolt.fill" : "arrow.up")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(canSend ? .white : (isEmptyConversation ? .white.opacity(0.35) : .secondary.opacity(0.5)))
                                .frame(width: 32, height: 32)
                                .background(
                                    canSend
                                        ? (chatViewModel.isAgentMode ? Color.cyan : (isEmptyConversation ? Color.white.opacity(0.28) : Color.accentColor))
                                        : (isEmptyConversation ? Color.white.opacity(0.12) : Color.primary.opacity(0.08)),
                                    in: .circle
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSend)
                        .help(chatViewModel.isAgentMode ? "Send Agent Task (Return)" : "Send Message (Return)")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .frame(minHeight: 52)
                .background(
                    isEmptyConversation
                        ? Color.black.opacity(0.25)
                        : (colorScheme == .dark ? Color(red: 0.12, green: 0.125, blue: 0.15) : Color.white),
                    in: .capsule
                )
                .overlay(
                    Capsule()
                        .stroke(
                            chatViewModel.isAgentMode
                                ? Color.cyan.opacity(0.55)
                                : (isEmptyConversation
                                    ? Color.white.opacity(0.18)
                                    : Color.primary.opacity(0.12)),
                            lineWidth: chatViewModel.isAgentMode ? 1.5 : 1
                        )
                )
                .shadow(
                    color: isEmptyConversation ? .clear : Color.black.opacity(colorScheme == .dark ? 0.25 : 0.05),
                    radius: 8,
                    y: 3
                )
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
                ForEach(chatViewModel.attachedImageURLs, id: \.self) { url in
                    HStack(spacing: 6) {
                        if let image = NSImage(contentsOf: url) {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 28, height: 28)
                                .clipShape(.rect(cornerRadius: 6))
                        }
                        Text(url.lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(isEmptyConversation ? Color.white : Color.primary)
                            .lineLimit(1)
                        Button {
                            chatViewModel.attachedImageURLs.removeAll { $0 == url }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(isEmptyConversation ? Color.white.opacity(0.8) : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        isEmptyConversation
                            ? Color.black.opacity(0.25)
                            : (colorScheme == .dark ? Color(white: 0.16) : Color(white: 0.92)),
                        in: .capsule
                    )
                    .overlay(
                        Capsule()
                            .stroke(isEmptyConversation ? Color.white.opacity(0.18) : Color.primary.opacity(0.12), lineWidth: 1)
                    )
                    .help(chatViewModel.selectedModelIsVisual ? "Image will be sent to the vision model" : "The selected model does not support images — this will not be sent")
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func attachmentChip(name: String, icon: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(isEmptyConversation ? Color.white : Color.primary)

            Text(name)
                .font(.caption)
                .foregroundStyle(isEmptyConversation ? Color.white : Color.primary)
                .lineLimit(1)

            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(isEmptyConversation ? Color.white.opacity(0.8) : Color.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            isEmptyConversation
                ? Color.black.opacity(0.25)
                : (colorScheme == .dark ? Color(white: 0.16) : Color(white: 0.92)),
            in: .capsule
        )
        .overlay(
            Capsule()
                .stroke(isEmptyConversation ? Color.white.opacity(0.18) : Color.primary.opacity(0.12), lineWidth: 1)
        )
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
                routeAttachment(url)
            }
        }
    }

    /// Routes an attached/dropped file to the right bucket: videos, images
    /// (vision pipeline), or generic files (text extraction).
    private func routeAttachment(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if ["mp4", "mov", "m4v", "avi", "mkv"].contains(ext) {
            chatViewModel.attachedVideoURL = url
        } else if ["png", "jpg", "jpeg", "heic", "heif", "gif", "tiff", "bmp", "webp"].contains(ext) {
            if !chatViewModel.attachedImageURLs.contains(url) {
                chatViewModel.attachedImageURLs.append(url)
            }
        } else if !chatViewModel.attachedFileURLs.contains(url) {
            chatViewModel.attachedFileURLs.append(url)
        }
    }

    /// Handles files/images dropped onto the chat (feature H drag-and-drop).
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    var fileURL: URL?
                    if let data = item as? Data {
                        fileURL = URL(dataRepresentation: data, relativeTo: nil)
                    } else if let url = item as? URL {
                        fileURL = url
                    }
                    if let fileURL {
                        Task { @MainActor in routeAttachment(fileURL) }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    let temp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("dropped-\(UUID().uuidString).png")
                    if (try? data.write(to: temp)) != nil {
                        Task { @MainActor in routeAttachment(temp) }
                    }
                }
            }
        }
        return handled
    }
}

// MARK: - Message Row View

private struct MessageRowView: View {
    @Environment(\.colorScheme) private var colorScheme
    let message: Message
    var toolCalls: [ToolCallRecord] = []
    /// True while this row is the assistant turn currently being generated.
    var isStreaming: Bool = false
    var onBranch: (() -> Void)? = nil
    var onRegenerate: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil
    @State private var copied = false
    @State private var tts = TTSService.shared

    private var isAssistant: Bool {
        message.role == .assistant
    }

    /// The message text as it may be shown. Assistant text passes the
    /// tool-invocation sanitizer first: raw invocation JSON and tool ids
    /// the model echoed into its reply are removed here even for messages
    /// saved before the sanitizer existed — tool activity belongs to the
    /// tool cards, never to the bubble.
    private var sanitizedContent: String {
        isAssistant
            ? ToolInvocationSanitizer.displayText(for: message.content, knownToolIDs: ToolsRegistry.shared.allToolIDs)
            : message.content
    }

    /// Assistant content split into reasoning vs. answer. The model's
    /// <thinking> blocks render in `ThinkingModelUI`, never inside the
    /// answer bubble; user and system messages parse to themselves.
    private var parsed: ThinkingContentParser.ParsedContent {
        isAssistant ? ThinkingContentParser.parse(sanitizedContent) : .init(answer: message.content)
    }

    /// The text the bubble renders — empty for an assistant turn that has
    /// produced nothing visible yet (still reasoning, or a tool turn whose
    /// prose was all invocation plumbing).
    private var bubbleText: String {
        isAssistant ? parsed.answer : message.content
    }

    private var hasBubble: Bool {
        !bubbleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                        Image(systemName: toolCalls.isEmpty ? "apple.intelligence" : "cpu")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(toolCalls.isEmpty ? Color.accentColor : Color.cyan)
                        Text(toolCalls.isEmpty ? "Locally" : "Locally Agent")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)
                    } else {
                        Text("You")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                    Text(message.timestamp, format: .dateTime.hour().minute())
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                // Completed Tool Calls in this assistant turn
                if isAssistant && !toolCalls.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(toolCalls) { record in
                            ToolCallView(record: record)
                        }
                    }
                    .padding(.bottom, 4)
                }

                // The model's reasoning, in its own separate UI above the
                // answer — never mixed into the answer bubble.
                if isAssistant && parsed.hasThinking {
                    ThinkingModelUI(
                        thinkingText: parsed.thinkingText,
                        isStreaming: isStreaming && parsed.isThinkingOpen
                    )
                }

                // Bubble — Markdown with full typography & code panels.
                // Assistant bubbles show the parsed answer only (thinking
                // blocks stripped). The bubble renders ONLY when there is
                // visible text: while the model is still reasoning, or a
                // tool turn is running, there is no answer yet — and an
                // empty bubble is just a black box on screen. The
                // generating indicator below the stream covers that state.
                if hasBubble {
                MarkdownContentView(content: bubbleText)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        (!isAssistant
                            ? Color.accentColor.opacity(colorScheme == .dark ? 0.28 : 0.16)
                            : (colorScheme == .dark
                                ? Color(red: 0.12, green: 0.125, blue: 0.15)
                                : Color.white)),
                        in: .rect(cornerRadius: 18)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(
                                !isAssistant
                                    ? Color.accentColor.opacity(0.35)
                                    : (colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)),
                                lineWidth: 1
                            )
                    )
                    .shadow(
                        color: isAssistant ? Color.black.opacity(colorScheme == .dark ? 0.2 : 0.05) : .clear,
                        radius: 6,
                        y: 2
                    )
                    .contextMenu {
                        Button("Copy Text", systemImage: "doc.on.doc") { copyText(bubbleText) }
                        if let onBranch {
                            Button("Branch From Here", systemImage: "arrow.branch", action: onBranch)
                        }
                        if !isAssistant, let onEdit {
                            Button("Edit & Resend", systemImage: "pencil", action: onEdit)
                        }
                        if isAssistant, let onRegenerate {
                            Button("Regenerate Response", systemImage: "arrow.clockwise", action: onRegenerate)
                        }
                    }
                }

                // Assistant action buttons (Copy & TTS) — these act on the
                // answer, not the reasoning shown in ThinkingModelUI.
                if isAssistant && !parsed.answer.isEmpty {
                    HStack(spacing: 12) {
                        Button {
                            copyText(parsed.answer)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                Text(copied ? "Copied" : "Copy")
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)

                        Button {
                            if tts.speakingMessageID == message.id {
                                tts.stop()
                            } else {
                                tts.speak(text: parsed.answer, messageID: message.id)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: tts.speakingMessageID == message.id ? "stop.circle.fill" : "speaker.wave.2")
                                Text(tts.speakingMessageID == message.id ? "Stop" : "Read Aloud")
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
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
