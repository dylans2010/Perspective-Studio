import SwiftUI
import SwiftData

@main
struct LocallyApp: App {
    @State private var selectedTab: SidebarTab = .chat
    @State private var chatViewModel = ChatViewModel()

    var body: some Scene {
        WindowGroup("Locally") {
            ContentView(selectedTab: $selectedTab, chatViewModel: chatViewModel)
        }
        .modelContainer(for: [UserProfile.self, Conversation.self, Message.self])
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    selectedTab = .settings
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(after: .newItem) {
                Button("New Chat") {
                    selectedTab = .chat
                }
                .keyboardShortcut("n", modifiers: .command)

                Divider()

                ForEach(SidebarTab.allCases) { tab in
                    Button("Go to \(tab.title)") {
                        selectedTab = tab
                    }
                    .keyboardShortcut(tab.keyEquivalent, modifiers: .command)
                }
            }
        }
    }
}
