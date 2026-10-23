import Foundation

/// Historical benchmark results, persisted as versioned JSON.
@Observable @MainActor
final class BenchmarkStore {
    static let shared = BenchmarkStore()

    private(set) var results: [BenchmarkResult] = []
    private let filename = "benchmarks.json"

    init() {
        results = JSONFileStore.load([BenchmarkResult].self, filename: filename) ?? []
    }

    func record(_ result: BenchmarkResult) {
        results.append(result)
        JSONFileStore.save(results, filename: filename)
    }

    func results(forModel modelID: String) -> [BenchmarkResult] {
        results.filter { $0.modelID == modelID }.sorted { $0.date > $1.date }
    }

    func deleteAll() {
        results = []
        JSONFileStore.save(results, filename: filename)
    }
}

/// Runs repeatable, *measured* benchmarks against a real installed model
/// through the unified backend (feature E). Load time is measured on the
/// first repetition (subsequent ones find the model already loaded and say
/// so via `loadSeconds == 0/nil` handling in the UI), TTFT / tok-s / totals
/// come from the actual token stream, and memory is the process's real
/// `phys_footprint` after generation.
@MainActor
enum BenchmarkService {
    static func run(
        model: InstalledModel,
        prompt: String,
        repetitions: Int = 1,
        backend: any InferenceBackend = InferenceBackends.default
    ) async throws -> BenchmarkResult {
        let reps = max(1, repetitions)
        var loadSeconds: Double?
        var ttfts: [Double] = []
        var totals: [Double] = []
        var tokenCounts: [Int] = []
        var lastMemory: Int64?

        for index in 0..<reps {
            let measuredLoad = try await backend.load(model: model)
            if index == 0 { loadSeconds = measuredLoad }
            let run = try await backend.generate(prompt: prompt, systemPrompt: nil)
            if let ttft = run.metrics.timeToFirstTokenSeconds { ttfts.append(ttft) }
            totals.append(run.metrics.totalSeconds)
            tokenCounts.append(run.metrics.outputTokens)
            lastMemory = run.metrics.memoryFootprintBytes ?? lastMemory
        }

        let totalSeconds = totals.reduce(0, +)
        let totalTokens = tokenCounts.reduce(0, +)
        let result = BenchmarkResult(
            modelID: model.id,
            promptPreview: String(prompt.prefix(80)),
            loadSeconds: loadSeconds,
            timeToFirstTokenSeconds: ttfts.isEmpty ? nil : ttfts.reduce(0, +) / Double(ttfts.count),
            totalSeconds: totalSeconds,
            outputTokens: totalTokens,
            tokensPerSecond: totalSeconds > 0 ? Double(totalTokens) / totalSeconds : nil,
            memoryFootprintBytes: lastMemory,
            repetitions: reps
        )
        BenchmarkStore.shared.record(result)
        return result
    }
}
