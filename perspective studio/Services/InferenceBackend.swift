import Foundation
import Darwin

/// Measured generation metrics. Every value here is *measured* by the backend
/// while a run actually happens — never estimated and never fabricated.
/// `nil` means "not measurable on this path", and the UI must say so.
struct GenerationMetrics: Sendable, Codable {
    /// Seconds spent loading the model into memory (only when this run loaded it).
    var loadSeconds: Double?
    /// Seconds from generation start until the first token arrived.
    var timeToFirstTokenSeconds: Double?
    /// Total generation seconds.
    var totalSeconds: Double = 0
    /// Stream chunks received, which correspond to generated tokens on the MLX path.
    var outputTokens: Int = 0
    /// Process physical memory footprint after the run, when readable.
    var memoryFootprintBytes: Int64?

    var tokensPerSecond: Double? {
        guard totalSeconds > 0, outputTokens > 0 else { return nil }
        return Double(outputTokens) / totalSeconds
    }
}

struct GenerationRun: Sendable {
    let text: String
    let metrics: GenerationMetrics
}

enum GenerationEvent: Sendable {
    case token(String)
    case finished(GenerationMetrics)
}

/// What a backend can honestly claim about a model. Capability claims must be
/// backed by evidence (model metadata / name / loaded configuration), so
/// `supportsVision` is only true for models the app's VLM path handles.
struct BackendCapabilities: Sendable {
    let supportsStreaming: Bool
    let supportsVision: Bool
    let supportsSystemPrompt: Bool
    /// The MLX chat path in this app does not expose native function calling;
    /// tool use is implemented by `ToolCallingService` on top of generation.
    let supportsNativeToolCalling: Bool
}

/// Unified inference abstraction (feature L). UI-facing features —
/// comparison, benchmarks, routing, tool calling, knowledge-base Q&A — go
/// through this protocol instead of depending on MLX types directly.
/// `LLMService` remains the single engine underneath the MLX backend; no
/// second engine is introduced.
protocol InferenceBackend: Sendable {
    var backendID: String { get }
    var displayName: String { get }

    func capabilities(for model: InstalledModel) -> BackendCapabilities
    /// Loads the model (downloading is *not* the backend's job — see
    /// `ModelDownloadService`) and returns the measured load time.
    func load(model: InstalledModel) async throws -> Double
    func unload() async
    func currentlyLoadedModelID() async -> String?
    /// Streams one self-contained prompt (fresh session, no chat history).
    func stream(prompt: String, systemPrompt: String?) throws -> AsyncThrowingStream<GenerationEvent, Error>
    func generate(prompt: String, systemPrompt: String?) async throws -> GenerationRun
}

extension InferenceBackend {
    func generate(prompt: String, systemPrompt: String?) async throws -> GenerationRun {
        let stream = try stream(prompt: prompt, systemPrompt: systemPrompt)
        var text = ""
        var metrics = GenerationMetrics()
        for try await event in stream {
            switch event {
            case .token(let token): text += token
            case .finished(let finalMetrics): metrics = finalMetrics
            }
        }
        return GenerationRun(text: text, metrics: metrics)
    }
}

/// MLX backend: a thin, honest wrapper over the existing `LLMService`.
struct MLXInferenceBackend: InferenceBackend {
    let backendID = "mlx"
    let displayName = "MLX (on-device)"

    nonisolated func capabilities(for model: InstalledModel) -> BackendCapabilities {
        BackendCapabilities(
            supportsStreaming: true,
            supportsVision: model.isVisual,
            supportsSystemPrompt: true,
            supportsNativeToolCalling: false
        )
    }

    nonisolated func load(model: InstalledModel) async throws -> Double {
        if await LLMService.shared.currentlyLoadedModelID() == model.id {
            return 0
        }
        let start = Date.now
        let stream = try await LLMService.shared.loadModelByID(model.id, isVideoModel: model.isVisual)
        for try await _ in stream { }
        try await LLMService.shared.finishLoading()
        return Date.now.timeIntervalSince(start)
    }

    nonisolated func unload() async {
        await LLMService.shared.unloadModel()
    }

    nonisolated func currentlyLoadedModelID() async -> String? {
        await LLMService.shared.currentlyLoadedModelID()
    }

    nonisolated func stream(prompt: String, systemPrompt: String?) throws -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let tokenStream = try await LLMService.shared.generateSinglePrompt(
                        prompt: prompt,
                        systemPrompt: systemPrompt
                    )
                    let start = Date.now
                    var firstTokenAt: Date?
                    var tokens = 0
                    for await token in tokenStream {
                        if Task.isCancelled { break }
                        if firstTokenAt == nil { firstTokenAt = .now }
                        tokens += 1
                        continuation.yield(.token(token))
                    }
                    var metrics = GenerationMetrics()
                    metrics.totalSeconds = Date.now.timeIntervalSince(start)
                    metrics.timeToFirstTokenSeconds = firstTokenAt.map { $0.timeIntervalSince(start) }
                    metrics.outputTokens = tokens
                    metrics.memoryFootprintBytes = MemoryUsage.currentFootprintBytes()
                    continuation.yield(.finished(metrics))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// The default backend used across the app.
enum InferenceBackends {
    static let `default`: any InferenceBackend = MLXInferenceBackend()
}

/// Real process memory readings (mach `phys_footprint`) — measured, not estimated.
enum MemoryUsage {
    nonisolated static func currentFootprintBytes() -> Int64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int64(info.phys_footprint)
    }
}
