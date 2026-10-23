import Foundation
import SwiftUI
import AppKit

enum ComparisonStatus: Equatable, Sendable {
    case idle
    case loading
    case generating
    case completed
    case error(String)

    var displayText: String {
        switch self {
        case .idle: "Ready"
        case .loading: "Loading weights..."
        case .generating: "Generating response..."
        case .completed: "Finished"
        case .error(let msg): "Error: \(msg)"
        }
    }

    var badgeColor: Color {
        switch self {
        case .idle: .secondary
        case .loading: .orange
        case .generating: .blue
        case .completed: .green
        case .error: .red
        }
    }
}

struct ComparisonResult: Identifiable, Sendable {
    let id: String
    var displayName: String
    var status: ComparisonStatus = .idle
    var response: String = ""
    var latencySeconds: Double = 0.0
    var tokensPerSecond: Double = 0.0
    var tokensCount: Int = 0
    var charactersCount: Int = 0
    /// Measured time to first token for this run (nil until the first token).
    var timeToFirstTokenSeconds: Double?
    /// Measured model load time for this run (0 when already loaded).
    var loadSeconds: Double = 0
}

@Observable
@MainActor
final class ModelComparisonViewModel {
    var selectedModelA: InstalledModel?
    var selectedModelB: InstalledModel?
    var prompt: String = ""
    var isComparing: Bool = false
    var isSequentialMode: Bool = true
    var memorySafetyNotice: String = "Unified Memory Protection Active"

    var resultA: ComparisonResult?
    var resultB: ComparisonResult?

    private var comparisonTask: Task<Void, Never>?

    init() {
        evaluateMemoryPressure()
    }

    func evaluateMemoryPressure() {
        let totalRAM = RAMService.totalRAMInGB
        // If Mac has <= 32GB RAM or models are heavy, enforce sequential loading to protect unified memory
        if totalRAM <= 36.0 {
            isSequentialMode = true
            memorySafetyNotice = "Sequential execution active (preserving Apple Silicon Unified Memory on \(Int(totalRAM))GB Mac)"
        } else {
            isSequentialMode = false
            memorySafetyNotice = "High memory bandwidth mode active (\(Int(totalRAM))GB Mac)"
        }
    }

    func startComparison() {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }
        guard let modelA = selectedModelA, let modelB = selectedModelB else { return }

        isComparing = true
        resultA = ComparisonResult(id: modelA.id, displayName: modelA.displayName, status: .idle)
        resultB = ComparisonResult(id: modelB.id, displayName: modelB.displayName, status: .idle)

        comparisonTask?.cancel()
        comparisonTask = Task {
            // Sequential execution for Apple Silicon unified memory safety
            await executeModelA(model: modelA, prompt: trimmedPrompt)

            if !Task.isCancelled {
                await executeModelB(model: modelB, prompt: trimmedPrompt)
            }

            self.isComparing = false
        }
    }

    func rerunModelA() {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty, let modelA = selectedModelA else { return }
        Task {
            isComparing = true
            await executeModelA(model: modelA, prompt: trimmedPrompt)
            isComparing = false
        }
    }

    func rerunModelB() {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty, let modelB = selectedModelB else { return }
        Task {
            isComparing = true
            await executeModelB(model: modelB, prompt: trimmedPrompt)
            isComparing = false
        }
    }

    func stopComparison() {
        comparisonTask?.cancel()
        comparisonTask = nil
        Task { await LLMService.shared.cancel() }
        isComparing = false
        if resultA?.status == .generating || resultA?.status == .loading {
            resultA?.status = .idle
        }
        if resultB?.status == .generating || resultB?.status == .loading {
            resultB?.status = .idle
        }
    }

    private func executeModelA(model: InstalledModel, prompt: String) async {
        resultA = ComparisonResult(id: model.id, displayName: model.displayName, status: .loading)
        let outcome = await executeViaBackend(model: model, prompt: prompt) { partial in
            self.resultA?.status = .generating
            self.resultA?.response = partial
            self.resultA?.charactersCount = partial.count
        }
        applyOutcome(outcome, to: \.resultA, model: model, prompt: prompt)
    }

    private func executeModelB(model: InstalledModel, prompt: String) async {
        resultB = ComparisonResult(id: model.id, displayName: model.displayName, status: .loading)
        // Sequential mode (the default under unified-memory pressure) unloads
        // the other model first; the backend load below is measured either way.
        if isSequentialMode,
           await InferenceBackends.default.currentlyLoadedModelID() != model.id {
            await InferenceBackends.default.unload()
        }
        let outcome = await executeViaBackend(model: model, prompt: prompt) { partial in
            self.resultB?.status = .generating
            self.resultB?.response = partial
            self.resultB?.charactersCount = partial.count
        }
        applyOutcome(outcome, to: \.resultB, model: model, prompt: prompt)
    }

    private struct ExecutionOutcome {
        var text: String = ""
        var metrics: GenerationMetrics = GenerationMetrics()
        var loadSeconds: Double = 0
        var errorMessage: String?
    }

    /// Runs one model through the unified backend (feature L), streaming
    /// partial text out and capturing *measured* load time, TTFT, tok/s.
    private func executeViaBackend(
        model: InstalledModel,
        prompt: String,
        onPartial: @escaping (String) -> Void
    ) async -> ExecutionOutcome {
        var outcome = ExecutionOutcome()
        do {
            outcome.loadSeconds = try await InferenceBackends.default.load(model: model)
            let stream = try InferenceBackends.default.stream(prompt: prompt, systemPrompt: nil)
            for try await event in stream {
                if Task.isCancelled { break }
                switch event {
                case .token(let token):
                    outcome.text += token
                    onPartial(outcome.text)
                case .finished(let metrics):
                    outcome.metrics = metrics
                }
            }
        } catch {
            outcome.errorMessage = error.localizedDescription
        }
        return outcome
    }

    private func applyOutcome(
        _ outcome: ExecutionOutcome,
        to keyPath: ReferenceWritableKeyPath<ModelComparisonViewModel, ComparisonResult?>,
        model: InstalledModel,
        prompt: String
    ) {
        if let errorMessage = outcome.errorMessage, outcome.text.isEmpty {
            self[keyPath: keyPath]?.status = .error(errorMessage)
            return
        }
        self[keyPath: keyPath]?.response = outcome.text
        self[keyPath: keyPath]?.charactersCount = outcome.text.count
        self[keyPath: keyPath]?.tokensCount = outcome.metrics.outputTokens
        self[keyPath: keyPath]?.latencySeconds = outcome.metrics.totalSeconds
        self[keyPath: keyPath]?.timeToFirstTokenSeconds = outcome.metrics.timeToFirstTokenSeconds
        self[keyPath: keyPath]?.loadSeconds = outcome.loadSeconds
        if let tps = outcome.metrics.tokensPerSecond {
            self[keyPath: keyPath]?.tokensPerSecond = tps
        }
        self[keyPath: keyPath]?.status = .completed

        // Every comparison run is also a measured benchmark record (feature E).
        BenchmarkStore.shared.record(BenchmarkResult(
            modelID: model.id,
            promptPreview: String(prompt.prefix(80)),
            loadSeconds: outcome.loadSeconds,
            timeToFirstTokenSeconds: outcome.metrics.timeToFirstTokenSeconds,
            totalSeconds: outcome.metrics.totalSeconds,
            outputTokens: outcome.metrics.outputTokens,
            tokensPerSecond: outcome.metrics.tokensPerSecond,
            memoryFootprintBytes: outcome.metrics.memoryFootprintBytes
        ))
    }

    func copyResponseA() {
        if let response = resultA?.response, !response.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(response, forType: .string)
        }
    }

    func copyResponseB() {
        if let response = resultB?.response, !response.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(response, forType: .string)
        }
    }
}
