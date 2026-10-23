import SwiftUI
import SwiftData

struct ChatView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var chatViewModel: ChatViewModel
    var isSidebarCollapsed: Bool = false
    var onToggleSidebar: (() -> Void)? = nil
    var onOpenSettings: (() -> Void)? = nil

    var body: some View {
        if let conversation = chatViewModel.selectedConversation {
            ChatDetailView(
                conversation: conversation,
                chatViewModel: chatViewModel,
                isSidebarCollapsed: isSidebarCollapsed,
                onToggleSidebar: onToggleSidebar,
                onOpenSettings: onOpenSettings
            )
        } else {
            // If no conversation is selected, automatically create or present draft
            DraftChatContainerView(
                chatViewModel: chatViewModel,
                isSidebarCollapsed: isSidebarCollapsed,
                onToggleSidebar: onToggleSidebar,
                onOpenSettings: onOpenSettings
            )
        }
    }
}

private struct DraftChatContainerView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var chatViewModel: ChatViewModel
    var isSidebarCollapsed: Bool = false
    var onToggleSidebar: (() -> Void)? = nil
    var onOpenSettings: (() -> Void)? = nil

    var body: some View {
        Color.clear
            .task {
                if chatViewModel.selectedConversation == nil {
                    chatViewModel.createConversation(in: modelContext)
                }
            }
    }
}
