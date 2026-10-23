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

        do {
            let currentlyLoaded = await LLMService.shared.currentlyLoadedModelID()
            if currentlyLoaded != model.id {
                let stream = try await LLMService.shared.loadModelByID(model.id, isVideoModel: model.isVisual)
                for try await _ in stream { }
                try await LLMService.shared.finishLoading()
            }

            resultA?.status = .generating
            let start = Date.now
            let tokenStream = try await LLMService.shared.generateSinglePrompt(prompt: prompt)

            var text = ""
            var tokenCount = 0
            for await token in tokenStream {
                if Task.isCancelled { break }
                text += token
                tokenCount += 1
                let elapsed = Date.now.timeIntervalSince(start)
                resultA?.response = text
                resultA?.charactersCount = text.count
                resultA?.tokensCount = tokenCount
                resultA?.latencySeconds = elapsed
                if elapsed > 0.1 {
                    resultA?.tokensPerSecond = Double(tokenCount) / elapsed
                }
            }

            let finalElapsed = Date.now.timeIntervalSince(start)
            resultA?.latencySeconds = finalElapsed
            if finalElapsed > 0.1 {
                resultA?.tokensPerSecond = Double(tokenCount) / finalElapsed
            }
            resultA?.status = .completed

        } catch {
            resultA?.status = .error(error.localizedDescription)
        }
    }

    private func executeModelB(model: InstalledModel, prompt: String) async {
        resultB = ComparisonResult(id: model.id, displayName: model.displayName, status: .loading)

        do {
            let currentlyLoaded = await LLMService.shared.currentlyLoadedModelID()
            if currentlyLoaded != model.id {
                // If model B is different, safely unload model A first to avoid unified memory pressure
                await LLMService.shared.unloadModel()
                let stream = try await LLMService.shared.loadModelByID(model.id, isVideoModel: model.isVisual)
                for try await _ in stream { }
                try await LLMService.shared.finishLoading()
            }

            resultB?.status = .generating
            let start = Date.now
            let tokenStream = try await LLMService.shared.generateSinglePrompt(prompt: prompt)

            var text = ""
            var tokenCount = 0
            for await token in tokenStream {
                if Task.isCancelled { break }
                text += token
                tokenCount += 1
                let elapsed = Date.now.timeIntervalSince(start)
                resultB?.response = text
                resultB?.charactersCount = text.count
                resultB?.tokensCount = tokenCount
                resultB?.latencySeconds = elapsed
                if elapsed > 0.1 {
                    resultB?.tokensPerSecond = Double(tokenCount) / elapsed
                }
            }

            let finalElapsed = Date.now.timeIntervalSince(start)
            resultB?.latencySeconds = finalElapsed
            if finalElapsed > 0.1 {
                resultB?.tokensPerSecond = Double(tokenCount) / finalElapsed
            }
            resultB?.status = .completed

        } catch {
            resultB?.status = .error(error.localizedDescription)
        }
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
