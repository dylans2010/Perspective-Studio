import SwiftUI
import SwiftData

struct ContentView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Binding var selectedTab: SidebarTab
    let chatViewModel: ChatViewModel

    var body: some View {
        if hasCompletedOnboarding {
            MainView(selectedTab: $selectedTab, chatViewModel: chatViewModel)
        } else {
            OnboardingContainerView {
                hasCompletedOnboarding = true
            }
        }
    }
}

// MARK: - Main View

enum SidebarTab: String, CaseIterable, Identifiable {
    case chat
    case downloads
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: "Chat"
        case .downloads: "Downloads"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right.fill"
        case .downloads: "arrow.down.circle.fill"
        case .settings: "gearshape.fill"
        }
    }

    var shortcutNumber: Int {
        switch self {
        case .chat: 1
        case .downloads: 2
        case .settings: 3
        }
    }

    var keyEquivalent: KeyEquivalent {
        switch self {
        case .chat: "1"
        case .downloads: "2"
        case .settings: "3"
        }
    }
}

struct MainView: View {
    @Environment(\.modelContext) private var modelContext
    @Binding var selectedTab: SidebarTab
    @Bindable var chatViewModel: ChatViewModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ConversationListView(
                selectedConversation: $chatViewModel.selectedConversation,
                onOpenSettings: {
                    selectedTab = .settings
                },
                onOpenDownloads: {
                    selectedTab = .downloads
                },
                onToggleSidebar: {
                    withAnimation {
                        columnVisibility = (columnVisibility == .detailOnly) ? .all : .detailOnly
                    }
                },
                onNewChat: {
                    selectedTab = .chat
                    chatViewModel.createConversation(in: modelContext)
                },
                onDelete: {
                    chatViewModel.deleteConversation($0, in: modelContext)
                }
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            switch selectedTab {
            case .chat:
                ChatView(
                    chatViewModel: chatViewModel,
                    onToggleSidebar: {
                        withAnimation {
                            columnVisibility = (columnVisibility == .detailOnly) ? .all : .detailOnly
                        }
                    },
                    onOpenSettings: {
                        selectedTab = .settings
                    }
                )
            case .downloads:
                DownloadsView(chatViewModel: chatViewModel, onClose: { selectedTab = .chat })
            case .settings:
                SettingsView(onClose: { selectedTab = .chat })
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: chatViewModel.selectedConversation) {
            selectedTab = .chat
            Task { await LLMService.shared.resetSession() }
        }
        .task {
            if chatViewModel.selectedConversation == nil {
                chatViewModel.createConversation(in: modelContext)
            }
            await chatViewModel.fetchModels()
        }
    }
}
