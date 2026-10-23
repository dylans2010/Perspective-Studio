import SwiftUI
import SwiftData

struct ConversationListView: View {
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @Binding var selectedConversation: Conversation?
    var onOpenSettings: (() -> Void)? = nil
    var onOpenDownloads: (() -> Void)? = nil
    var onOpenCompare: (() -> Void)? = nil
    var onOpenAPIServer: (() -> Void)? = nil
    var onBackToChat: (() -> Void)? = nil
    let onNewChat: () -> Void
    let onDelete: (Conversation) -> Void

    @AppStorage("chatGradientTheme") private var gradientPresetRaw: String = GradientPreset.aurora.rawValue
    @AppStorage("chatGradientTopHex") private var customTopHex: String = GradientTheme.defaultTopHex
    @AppStorage("chatGradientBottomHex") private var customBottomHex: String = GradientTheme.defaultBottomHex

    @State private var searchQuery: String = ""

    private var activeGradientColors: [Color] {
        GradientTheme.activeColors(
            presetRaw: gradientPresetRaw,
            customTopHex: customTopHex,
            customBottomHex: customBottomHex
        )
    }

    private var filteredConversations: [Conversation] {
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return conversations
        }
        return conversations.filter {
            $0.title.localizedStandardContains(searchQuery)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top Bar: Traffic lights spacing on left, action icons on right
            HStack(spacing: 6) {
                // Reserved space for macOS traffic lights (red, yellow, green)
                Spacer()
                    .frame(width: 68)

                Spacer()

                if let onOpenCompare {
                    Button {
                        onOpenCompare()
                    } label: {
                        Image(systemName: "square.split.2x1")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 28, height: 28)
                            .liquidGlass(.circle)
                    }
                    .buttonStyle(.plain)
                    .help("Model Comparison")
                }

                if let onOpenAPIServer {
                    Button {
                        onOpenAPIServer()
                    } label: {
                        Image(systemName: "server.rack")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 28, height: 28)
                            .liquidGlass(.circle)
                    }
                    .buttonStyle(.plain)
                    .help("Local API Server")
                }

                if let onOpenDownloads {
                    Button {
                        onOpenDownloads()
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 28, height: 28)
                            .liquidGlass(.circle)
                    }
                    .buttonStyle(.plain)
                    .help("Downloads & Models")
                }

                if let onOpenSettings {
                    Button {
                        onOpenSettings()
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 28, height: 28)
                            .liquidGlass(.circle)
                    }
                    .buttonStyle(.plain)
                    .help("Settings")
                }

                if let onBackToChat {
                    Button {
                        onBackToChat()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 28, height: 28)
                            .liquidGlass(.circle)
                    }
                    .buttonStyle(.plain)
                    .help("Back to Chat")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Search Bar Capsule (Exact Image 2)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))

                TextField("Search", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)

                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .liquidGlass(.capsule, isClear: true)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            // Recents Header
            Text("Recents")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))
                .padding(.horizontal, 16)
                .padding(.bottom, 6)

            // Conversation Items List
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(filteredConversations) { conversation in
                        Button {
                            selectedConversation = conversation
                            onBackToChat?()
                        } label: {
                            ConversationRowView(conversation: conversation)
                                .background(
                                    selectedConversation?.id == conversation.id
                                        ? Color.white.opacity(0.14)
                                        : Color.clear,
                                    in: .rect(cornerRadius: 10)
                                )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                onDelete(conversation)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            .overlay {
                if filteredConversations.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "bubble.left")
                            .font(.system(size: 24))
                            .foregroundStyle(.white.opacity(0.4))
                        Text(searchQuery.isEmpty ? "No Chats Yet" : "No Matches")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                        Spacer()
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(
            ZStack {
                LinearGradient(
                    colors: activeGradientColors,
                    startPoint: .top,
                    endPoint: .bottom
                )
                // Subtle darkening veil that blends seamlessly with the main chat view
                Color.black.opacity(0.20)
            }
            .ignoresSafeArea()
        )
    }
}
