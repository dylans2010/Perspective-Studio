import SwiftUI

/// The Studio hub (features E, F, I, J, K): benchmarks, prompt library,
/// knowledge bases, model routing, and tools — reached from the new Studio
/// sidebar tab, in the app's existing design language.
struct StudioView: View {
    @Bindable var chatViewModel: ChatViewModel
    var onClose: (() -> Void)? = nil

    private enum Section: String, CaseIterable, Identifiable {
        case benchmarks = "Benchmarks"
        case prompts = "Prompts & Profiles"
        case knowledge = "Knowledge"
        case routing = "Routing"
        case tools = "Tools"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .benchmarks: "gauge.with.dots.needle.67percent"
            case .prompts: "text.book.closed"
            case .knowledge: "books.vertical"
            case .routing: "arrow.triangle.branch"
            case .tools: "wrench.and.screwdriver"
            }
        }
    }

    @State private var section: Section = .benchmarks

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Studio", systemImage: "flask.fill")
                    .font(.title3)
                    .bold()
                Spacer()
                if let onClose {
                    Button("Back to Chat", systemImage: "bubble.left.and.bubble.right") { onClose() }
                        .buttonStyle(.bordered)
                }
            }
            .padding()

            Picker("Studio section", selection: $section) {
                ForEach(Section.allCases) { item in
                    Label(item.rawValue, systemImage: item.systemImage).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            Divider()
                .padding(.top)

            switch section {
            case .benchmarks:
                BenchmarksView(chatViewModel: chatViewModel)
            case .prompts:
                PromptLibraryView(chatViewModel: chatViewModel)
            case .knowledge:
                KnowledgeBaseView(chatViewModel: chatViewModel)
            case .routing:
                ModelRoutingView(chatViewModel: chatViewModel)
            case .tools:
                ToolsView(chatViewModel: chatViewModel)
            }
        }
        .task { chatViewModel.scanInstalledModels() }
    }
}
