import SwiftUI
import AppKit

/// Knowledge bases (feature I): import local documents, search the local
/// index with citations, and ask questions answered from retrieved passages.
/// Everything stays on this Mac; chat injection is opt-in.
struct KnowledgeBaseView: View {
    @Bindable var chatViewModel: ChatViewModel
    @State private var store = KnowledgeBaseStore.shared
    @AppStorage("knowledgeUseInChat") private var useInChat = false

    @State private var searchQuery = ""
    @State private var passages: [KBPassage] = []
    @State private var question = ""
    @State private var answer = ""
    @State private var answerCitations: [String] = []
    @State private var isAsking = false
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Button {
                        importDocuments()
                    } label: {
                        Label("Import Documents…", systemImage: "doc.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isIndexing)

                    Button("Reindex All") {
                        Task { await store.reindexAll() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.documents.isEmpty || store.isIndexing)

                    if store.isIndexing {
                        ProgressView().controlSize(.small)
                        Text(store.indexingStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(store.documents.count) documents · \(store.chunks.count) passages indexed locally")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Use knowledge base in Chat (retrieved passages are added as cited context)", isOn: $useInChat)

                if let error = store.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }

                if store.documents.isEmpty {
                    ContentUnavailableView(
                        "No Documents Yet",
                        systemImage: "books.vertical",
                        description: Text("Import PDF, Markdown, text, or source files. They are chunked and indexed on this Mac only.")
                    )
                } else {
                    ForEach(store.documents) { document in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(document.title).bold()
                                Text("\(document.chunkCount) passages · \(document.characterCount) characters · \(document.sourcePath)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button("Remove", role: .destructive) { store.removeDocument(document) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                        .padding(10)
                        .background(.regularMaterial)
                        .clipShape(.rect(cornerRadius: 10))
                    }
                }

                Divider()

                GroupBox("Search the Index") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("Search your documents", text: $searchQuery)
                                .textFieldStyle(.roundedBorder)
                            Button("Search") {
                                passages = store.search(query: searchQuery)
                            }
                            .buttonStyle(.bordered)
                            .disabled(searchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        ForEach(passages) { passage in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(passage.citation)
                                    .font(.caption)
                                    .bold()
                                Text(passage.chunk.text)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(4)
                            }
                        }
                    }
                }

                GroupBox("Ask Your Documents") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Question", text: $question, axis: .vertical)
                            .lineLimit(2...4)
                        HStack {
                            Button {
                                ask()
                            } label: {
                                Label("Ask with Sources", systemImage: "text.bubble")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || isAsking || store.documents.isEmpty)
                            if isAsking { ProgressView().controlSize(.small) }
                        }
                        if let errorText {
                            Text(errorText).font(.caption).foregroundStyle(.red)
                        }
                        if !answer.isEmpty {
                            Text(answer)
                                .textSelection(.enabled)
                            if !answerCitations.isEmpty {
                                Text("Sources: \(answerCitations.joined(separator: "  "))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding()
        }
    }

    private func importDocuments() {
        let panel = NSOpenPanel()
        panel.title = "Import Documents"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task { await store.importFiles(urls) }
        }
    }

    private func ask() {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let found = store.search(query: trimmed)
        guard !found.isEmpty else {
            errorText = "No passages in your documents match that question."
            return
        }
        guard let model = chatViewModel.installedModels.first(where: { $0.id == chatViewModel.selectedModelID })
            ?? chatViewModel.installedModels.first else {
            errorText = "Download a model first — answers are generated locally by an installed model."
            return
        }
        isAsking = true
        errorText = nil
        answerCitations = found.map(\.citation)
        let context = found.map { "\($0.citation)\n\($0.chunk.text)" }.joined(separator: "\n\n")
        Task {
            do {
                _ = try await InferenceBackends.default.load(model: model)
                let run = try await InferenceBackends.default.generate(
                    prompt: trimmed,
                    systemPrompt: "Answer using only these passages from the user's local documents, and cite them like [Title · passage N]:\n\n\(context)"
                )
                answer = run.text
            } catch {
                errorText = error.localizedDescription
            }
            isAsking = false
        }
    }
}
