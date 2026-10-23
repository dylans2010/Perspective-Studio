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
    case compare
    case apiServer
    case downloads
    case studio
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: "Chat"
        case .compare: "Compare"
        case .apiServer: "Local API"
        case .downloads: "Downloads"
        case .studio: "Studio"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right.fill"
        case .compare: "square.split.2x1"
        case .apiServer: "server.rack"
        case .downloads: "arrow.down.circle.fill"
        case .studio: "flask.fill"
        case .settings: "gearshape.fill"
        }
    }

    var shortcutNumber: Int {
        switch self {
        case .chat: 1
        case .compare: 2
        case .apiServer: 3
        case .downloads: 4
        case .studio: 6
        case .settings: 5
        }
    }

    var keyEquivalent: KeyEquivalent {
        switch self {
        case .chat: "1"
        case .compare: "2"
        case .apiServer: "3"
        case .downloads: "4"
        case .studio: "6"
        case .settings: "5"
        }
    }
}

struct MainView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Binding var selectedTab: SidebarTab
    @Bindable var chatViewModel: ChatViewModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ConversationListView(
                selectedConversation: $chatViewModel.selectedConversation,
                onOpenSettings: {
                    openWindow(id: "settings")
                },
                onOpenDownloads: {
                    selectedTab = .downloads
                },
                onOpenCompare: {
                    selectedTab = .compare
                },
                onOpenAPIServer: {
                    selectedTab = .apiServer
                },
                onBackToChat: {
                    selectedTab = .chat
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
                    isSidebarCollapsed: columnVisibility == .detailOnly,
                    onToggleSidebar: {
                        withAnimation {
                            columnVisibility = (columnVisibility == .detailOnly) ? .all : .detailOnly
                        }
                    },
                    onOpenSettings: {
                        openWindow(id: "settings")
                    }
                )
            case .compare:
                ModelComparisonView(chatViewModel: chatViewModel, onClose: { selectedTab = .chat })
            case .apiServer:
                LocalAPIServerView(chatViewModel: chatViewModel, onClose: { selectedTab = .chat })
            case .downloads:
                DownloadsView(chatViewModel: chatViewModel, onClose: { selectedTab = .chat })
            case .studio:
                StudioView(chatViewModel: chatViewModel, onClose: { selectedTab = .chat })
            case .settings:
                SettingsView(onClose: { selectedTab = .chat })
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onReceive(NotificationCenter.default.publisher(for: .locallyQuickChat)) { _ in
            openWindow(id: "quick-chat")
        }
        .onChange(of: chatViewModel.selectedConversation?.id) {
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
