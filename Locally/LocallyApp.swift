import SwiftUI
import SwiftData

@main
struct LocallyApp: App {
    @State private var selectedTab: SidebarTab = .chat
    @State private var chatViewModel = ChatViewModel()
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(LocallyAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(selectedTab: $selectedTab, chatViewModel: chatViewModel)
        }
        .windowStyle(.hiddenTitleBar)
        .modelContainer(for: [UserProfile.self, Conversation.self, Message.self])
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    openWindow(id: "settings")
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(after: .newItem) {
                Button("Quick Chat") {
                    openWindow(id: "quick-chat")
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Button("New Chat") {
                    selectedTab = .chat
                }
                .keyboardShortcut("n", modifiers: .command)

                Divider()

                ForEach(SidebarTab.allCases) { tab in
                    Button("Go to \(tab.title)") {
                        if tab == .settings {
                            openWindow(id: "settings")
                        } else {
                            selectedTab = tab
                        }
                    }
                    .keyboardShortcut(tab.keyEquivalent, modifiers: .command)
                }
            }
        }

        Window("Locally Settings", id: "settings") {
            SettingsView(onClose: nil)
                .modelContainer(for: [UserProfile.self, Conversation.self, Message.self])
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 820, height: 620)

        // Compact chat window (feature M) — also the global-hotkey target.
        Window("Quick Chat", id: "quick-chat") {
            QuickChatView(chatViewModel: chatViewModel)
        }
        .windowResizability(.contentSize)

        // Menu-bar companion (feature M).
        MenuBarExtra("Locally Quick Chat", systemImage: "cpu") {
            QuickChatView(chatViewModel: chatViewModel)
        }
        .menuBarExtraStyle(.window)
    }
}
