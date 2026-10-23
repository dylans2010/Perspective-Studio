import Foundation

/// A reusable generation configuration, optionally bound to one model.
/// Fields are always saved; whether each is *applied* depends on the active
/// backend — the MLX chat path in this app applies temperature and the system
/// prompt today, so the UI labels the rest as "applied where supported"
/// instead of pretending they change the engine.
nonisolated struct GenerationProfile: Codable, Identifiable, Sendable, Hashable {
    var id: UUID = UUID()
    var name: String
    /// `nil` means the profile applies to any model.
    var modelID: String?
    var systemPrompt: String = ""
    var temperature: Double = 0.7
    var topP: Double = 1.0
    var topK: Int = 0
    var repetitionPenalty: Double = 1.0
    var maxOutputTokens: Int = 1024
    var contextLength: Int = 4096

    /// Names of the settings the current MLX backend actually applies.
    var appliedSettingsDescription: String {
        "Applies temperature and system prompt on the MLX backend; top-p, top-k, repetition penalty, output and context limits are stored and applied where a backend supports them."
    }
}

/// One measured benchmark run. All metrics come from a real generation via
/// `InferenceBackend` — estimates are never written into this store.
nonisolated struct BenchmarkResult: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var date: Date = .now
    var modelID: String
    var promptPreview: String
    var loadSeconds: Double?
    var timeToFirstTokenSeconds: Double?
    var totalSeconds: Double
    var outputTokens: Int
    var tokensPerSecond: Double?
    var memoryFootprintBytes: Int64?
    var repetitions: Int = 1
}
