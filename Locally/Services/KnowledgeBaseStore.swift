import Foundation
import PDFKit

/// File types the knowledge base can extract text from (PDF + plain-text formats).
nonisolated private let kbSupportedExtensions: Set<String> = [
    "pdf", "md", "markdown", "txt", "text",
    "swift", "ts", "tsx", "js", "jsx", "py", "rs", "go", "java", "c", "h",
    "cpp", "hpp", "cs", "rb", "php", "json", "yaml", "yml", "toml", "xml", "html", "css",
]

nonisolated struct KBDocument: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var title: String
    var sourcePath: String
    var importedAt: Date = .now
    var chunkCount: Int = 0
    var characterCount: Int = 0
}

nonisolated struct KBChunk: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var documentID: UUID
    var index: Int
    var text: String
}

/// A retrieved passage with the citation the UI / prompt must show.
nonisolated struct KBPassage: Identifiable, Sendable {
    var id: UUID { chunk.id }
    let chunk: KBChunk
    let documentTitle: String
    let score: Double

    var citation: String { "[\(documentTitle) · passage \(chunk.index + 1)]" }
}

enum KnowledgeBaseError: LocalizedError {
    case unsupportedFile(String)
    case unreadable(String)
    case emptyDocument(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile(let name): "\(name) is not a supported document type (PDF, Markdown, text, or source code)"
        case .unreadable(let name): "Could not read \(name) — check the file's permissions"
        case .emptyDocument(let name): "\(name) contains no extractable text"
        }
    }
}

/// Local knowledge bases (feature I). Documents are imported, chunked, and
/// indexed **entirely on this Mac** (versioned JSON under Application
/// Support). Retrieval is term-frequency scoring over the local index —
/// real retrieval over the user's own documents, with citations, and no
/// content ever leaves the device unless the user pastes it into a prompt
/// themselves.
@Observable @MainActor
final class KnowledgeBaseStore {
    static let shared = KnowledgeBaseStore()

    private(set) var documents: [KBDocument] = []
    private(set) var chunks: [KBChunk] = []
    var isIndexing: Bool = false
    var indexingStatus: String = ""
    var lastError: String?

    private let documentsFile = "knowledge-documents.json"
    private let chunksFile = "knowledge-chunks.json"


    init() {
        documents = JSONFileStore.load([KBDocument].self, filename: documentsFile) ?? []
        chunks = JSONFileStore.load([KBChunk].self, filename: chunksFile) ?? []
    }

    // MARK: - Import + indexing

    /// Imports files, extracts text off the main actor, chunks, and indexes.
    /// Inaccessible or unsupported files are reported in `lastError` and
    /// skipped safely — one bad file never blocks the rest.
    func importFiles(_ urls: [URL]) async {
        isIndexing = true
        lastError = nil
        defer { isIndexing = false; indexingStatus = "" }

        for url in urls {
            indexingStatus = "Indexing \(url.lastPathComponent)…"
            do {
                let (document, newChunks) = try await Self.extractAndChunk(url: url)
                // Re-importing the same path replaces the old version of that document.
                if let previous = documents.first(where: { $0.sourcePath == document.sourcePath }) {
                    chunks.removeAll { $0.documentID == previous.id }
                    documents.removeAll { $0.id == previous.id }
                }
                documents.append(document)
                chunks.append(contentsOf: newChunks)
                persist()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func removeDocument(_ document: KBDocument) {
        documents.removeAll { $0.id == document.id }
        chunks.removeAll { $0.documentID == document.id }
        persist()
    }

    func reindexAll() async {
        let paths = documents.map(\.sourcePath)
        documents = []
        chunks = []
        persist()
        await importFiles(paths.map { URL(fileURLWithPath: $0) })
    }

    // MARK: - Retrieval

    /// Scores every chunk against the query by term frequency over distinct
    /// query terms and returns the best passages, best first.
    nonisolated static func search(
        query: String,
        chunks: [KBChunk],
        documents: [KBDocument],
        limit: Int = 4
    ) -> [KBPassage] {
        let terms = Set(
            query.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 }
        )
        guard !terms.isEmpty else { return [] }
        let titles = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0.title) })

        let scored: [KBPassage] = chunks.compactMap { chunk in
            let lower = chunk.text.lowercased()
            var score = 0.0
            for term in terms {
                let count = lower.components(separatedBy: term).count - 1
                if count > 0 { score += Double(count) }
            }
            guard score > 0 else { return nil }
            // Mild normalization so a long chunk doesn't win on volume alone.
            let normalized = score / (1.0 + Double(chunk.text.count) / 4000.0)
            return KBPassage(chunk: chunk, documentTitle: titles[chunk.documentID] ?? "Document", score: normalized)
        }
        return scored.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    func search(query: String, limit: Int = 4) -> [KBPassage] {
        Self.search(query: query, chunks: chunks, documents: documents, limit: limit)
    }

    /// Builds a citation-carrying context block for a generation prompt.
    func contextBlock(for query: String, limit: Int = 4) -> String? {
        let passages = search(query: query, limit: limit)
        guard !passages.isEmpty else { return nil }
        return passages.map { "\($0.citation)\n\($0.chunk.text)" }.joined(separator: "\n\n")
    }

    // MARK: - Extraction + chunking (off the main actor)

    nonisolated static func extractAndChunk(url: URL) async throws -> (KBDocument, [KBChunk]) {
        try await Task.detached(priority: .userInitiated) {
            let ext = url.pathExtension.lowercased()
            guard kbSupportedExtensions.contains(ext) else {
                throw KnowledgeBaseError.unsupportedFile(url.lastPathComponent)
            }
            let text: String
            if ext == "pdf" {
                guard let pdf = PDFDocument(url: url) else {
                    throw KnowledgeBaseError.unreadable(url.lastPathComponent)
                }
                var pages: [String] = []
                for index in 0..<pdf.pageCount {
                    if let pageText = pdf.page(at: index)?.string { pages.append(pageText) }
                }
                text = pages.joined(separator: "\n\n")
            } else {
                guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
                    throw KnowledgeBaseError.unreadable(url.lastPathComponent)
                }
                text = contents
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw KnowledgeBaseError.emptyDocument(url.lastPathComponent)
            }
            let documentID = UUID()
            let chunkTexts = chunkText(trimmed, chunkSize: 900, overlap: 150)
            let kbChunks = chunkTexts.enumerated().map { index, chunkText in
                KBChunk(documentID: documentID, index: index, text: chunkText)
            }
            let document = KBDocument(
                id: documentID,
                title: url.deletingPathExtension().lastPathComponent,
                sourcePath: url.path,
                importedAt: .now,
                chunkCount: kbChunks.count,
                characterCount: trimmed.count
            )
            return (document, kbChunks)
        }.value
    }

    /// Splits text into overlapping chunks, preferring whitespace boundaries.
    nonisolated static func chunkText(_ text: String, chunkSize: Int, overlap: Int) -> [String] {
        guard text.count > chunkSize else { return [text] }
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            var end = text.index(start, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            if end < text.endIndex, let space = text[start..<end].lastIndex(of: " ") {
                end = space
            }
            let chunk = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { chunks.append(chunk) }
            if end >= text.endIndex { break }
            let advance = max(chunkSize - overlap, 1)
            start = text.index(start, offsetBy: advance, limitedBy: text.endIndex) ?? text.endIndex
        }
        return chunks
    }

    private func persist() {
        JSONFileStore.save(documents, filename: documentsFile)
        JSONFileStore.save(chunks, filename: chunksFile)
    }
}
