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
            VStack(spacing: 0) {
                List(selection: $selectedTab) {
                    ForEach(SidebarTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.symbol)
                            .tag(tab)
                    }
                }
                .listStyle(.sidebar)

                if selectedTab == .chat {
                    Divider()
                    ConversationListView(
                        selectedConversation: $chatViewModel.selectedConversation,
                        onNewChat: { chatViewModel.createConversation(in: modelContext) },
                        onDelete: { chatViewModel.deleteConversation($0, in: modelContext) }
                    )
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
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
                DownloadsView(chatViewModel: chatViewModel)
            case .settings:
                SettingsView()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: selectedTab) { _, newTab in
            if newTab == .chat && chatViewModel.selectedConversation == nil {
                chatViewModel.createConversation(in: modelContext)
            }
        }
        .onChange(of: chatViewModel.selectedConversation) {
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
