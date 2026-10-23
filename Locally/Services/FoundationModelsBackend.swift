import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// Thin adapter over `LanguageModelSession` that speaks the app's
/// `GenerationEvent` vocabulary and reports only *measured* metrics.
///
/// `ResponseStream` yields cumulative snapshots of the response, so the
/// adapter emits the delta between snapshots — the UI appends tokens exactly
/// like it does for the MLX backend.
@available(macOS 26.0, *)
nonisolated enum AppleLanguageModel {
    nonisolated static func stream(
        prompt: String,
        systemPrompt: String?,
        temperature: Double? = nil
    ) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // A fresh session per run: the app passes a self-contained
                    // prompt (history included), and a new session also clears
                    // the model's 4K-token context between turns.
                    let session = LanguageModelSession(instructions: systemPrompt)
                    let options = GenerationOptions(temperature: temperature)
                    let start = Date.now
                    var accumulated = ""
                    var firstTokenAt: Date?

                    for try await snapshot in session.streamResponse(to: prompt, options: options) {
                        try Task.checkCancellation()
                        let text = snapshot.content
                        // Snapshots are cumulative; a non-prefix snapshot (a
                        // fresh generation) is emitted in full instead.
                        let delta = text.hasPrefix(accumulated)
                            ? String(text.dropFirst(accumulated.count))
                            : text
                        accumulated = text
                        guard !delta.isEmpty else { continue }
                        if firstTokenAt == nil { firstTokenAt = .now }
                        continuation.yield(.token(delta))
                    }

                    var metrics = GenerationMetrics()
                    metrics.totalSeconds = Date.now.timeIntervalSince(start)
                    metrics.timeToFirstTokenSeconds = firstTokenAt.map { $0.timeIntervalSince(start) }
                    metrics.memoryFootprintBytes = MemoryUsage.currentFootprintBytes()
                    if #available(macOS 26.4, *) {
                        // The framework can count tokens, so this is measured
                        // rather than estimated from character counts.
                        metrics.outputTokens = (try? await SystemLanguageModel.default.tokenCount(for: accumulated)) ?? 0
                    }
                    continuation.yield(.finished(metrics))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AppleLanguageModelError.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Translates framework errors into messages that name the fix.
///
/// macOS 26 reports `LanguageModelSession.GenerationError`; macOS 27 replaced
/// it with the unified `LanguageModelError`, so both are mapped.
@available(macOS 26.0, *)
nonisolated enum AppleLanguageModelError {
    nonisolated static func map(_ error: Error) -> Error {
        if error is CancellationError { return error }

        if #available(macOS 27.0, *), let unified = error as? LanguageModelError {
            return AppleFoundationModelError(message: message(for: unified))
        }
        if let generation = error as? LanguageModelSession.GenerationError {
            return AppleFoundationModelError(message: message(for: generation))
        }
        return AppleFoundationModelError(
            message: "The built-in Apple model could not finish: \(error.localizedDescription)"
        )
    }

    @available(macOS 27.0, *)
    private static func message(for error: LanguageModelError) -> String {
        switch error {
        case .contextSizeExceeded:
            "This request is longer than the Apple model's context window. Start a new chat, shorten the message, or switch to a downloaded model with a larger context."
        case .rateLimited:
            "Apple Intelligence is busy right now. Wait a moment and try again."
        case .guardrailViolation:
            "Apple's safety guardrails blocked that response. Rephrase the request and try again."
        case .refusal:
            "The on-device model declined this request."
        case .unsupportedCapability:
            "The built-in model does not support this kind of request."
        case .unsupportedTranscriptContent:
            "The built-in model could not read part of this conversation."
        case .unsupportedGenerationGuide:
            "The built-in model could not follow the requested response format."
        case .unsupportedLanguageOrLocale:
            "The built-in model does not support this language yet. Switch to a downloaded model or change your language in System Settings."
        case .timeout:
            "The built-in model timed out. Try a shorter prompt."
        @unknown default:
            "The built-in model stopped unexpectedly. Try again."
        }
    }

    private static func message(for error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .exceededContextWindowSize:
            "This request is longer than the Apple model's context window. Start a new chat, shorten the message, or switch to a downloaded model with a larger context."
        case .assetsUnavailable:
            "Apple Intelligence is still preparing its model. Try again once the download finishes."
        case .rateLimited, .concurrentRequests:
            "Apple Intelligence is busy right now. Wait a moment and try again."
        case .guardrailViolation:
            "Apple's safety guardrails blocked that response. Rephrase the request and try again."
        case .refusal:
            "The on-device model declined this request."
        case .unsupportedGuide:
            "The built-in model could not follow the requested response format."
        case .unsupportedLanguageOrLocale:
            "The built-in model does not support this language yet. Switch to a downloaded model or change your language in System Settings."
        case .decodingFailure:
            "The built-in model returned content in an unexpected shape. Try again."
        @unknown default:
            "The built-in model stopped unexpectedly. Try again."
        }
    }
}

/// Inference backend for Apple Intelligence. It is the app's default model
/// whenever no MLX model is installed, and remains selectable afterwards.
@available(macOS 26.0, *)
struct FoundationModelsInferenceBackend: InferenceBackend {
    let backendID = AppleFoundationModel.backendID
    let displayName = "Apple Intelligence (built-in)"

    nonisolated func capabilities(for model: InstalledModel) -> BackendCapabilities {
        BackendCapabilities(
            supportsStreaming: true,
            // The text model has no vision path wired up in this app.
            supportsVision: false,
            supportsSystemPrompt: true,
            // The agent runtime hands the session real `Tool` conformances
            // instead of parsing text, unlike the MLX path.
            supportsNativeToolCalling: true
        )
    }

    nonisolated func load(model: InstalledModel) async throws -> Double {
        let availability = AppleFoundationModel.availability
        guard availability.isAvailable else {
            throw AppleFoundationModelError(message: availability.explanation)
        }
        // Nothing to load from disk; asking the framework to prewarm the
        // session is the closest honest equivalent and cuts first-token time.
        LanguageModelSession().prewarm()
        return 0
    }

    nonisolated func unload() async {
        // Sessions are created per run and released with them.
    }

    nonisolated func currentlyLoadedModelID() async -> String? {
        AppleFoundationModel.isAvailable ? AppleFoundationModel.modelID : nil
    }

    nonisolated func stream(
        prompt: String,
        systemPrompt: String?
    ) throws -> AsyncThrowingStream<GenerationEvent, Error> {
        AppleLanguageModel.stream(prompt: prompt, systemPrompt: systemPrompt)
    }
}

#else

/// Placeholder used when built against an SDK that predates Foundation Models;
/// it keeps the app compiling and fails with the same explanation the UI shows.
@available(macOS 26.0, *)
struct FoundationModelsInferenceBackend: InferenceBackend {
    let backendID = AppleFoundationModel.backendID
    let displayName = "Apple Intelligence (built-in)"

    nonisolated func capabilities(for model: InstalledModel) -> BackendCapabilities {
        BackendCapabilities(
            supportsStreaming: false,
            supportsVision: false,
            supportsSystemPrompt: false,
            supportsNativeToolCalling: false
        )
    }

    nonisolated func load(model: InstalledModel) async throws -> Double {
        throw AppleFoundationModelError(message: AppleFoundationModel.availability.explanation)
    }

    nonisolated func unload() async {}

    nonisolated func currentlyLoadedModelID() async -> String? { nil }

    nonisolated func stream(
        prompt: String,
        systemPrompt: String?
    ) throws -> AsyncThrowingStream<GenerationEvent, Error> {
        throw AppleFoundationModelError(message: AppleFoundationModel.availability.explanation)
    }
}

#endif

/// Backend reported when the running Mac cannot host the built-in model
/// (macOS 15–25, or Foundation Models unavailable at build time).
struct UnavailableAppleModelBackend: InferenceBackend {
    let backendID = AppleFoundationModel.backendID
    let displayName = "Apple Intelligence (built-in)"

    nonisolated func capabilities(for model: InstalledModel) -> BackendCapabilities {
        BackendCapabilities(
            supportsStreaming: false,
            supportsVision: false,
            supportsSystemPrompt: false,
            supportsNativeToolCalling: false
        )
    }

    nonisolated func load(model: InstalledModel) async throws -> Double {
        throw AppleFoundationModelError(message: AppleFoundationModel.availability.explanation)
    }

    nonisolated func unload() async {}

    nonisolated func currentlyLoadedModelID() async -> String? { nil }

    nonisolated func stream(
        prompt: String,
        systemPrompt: String?
    ) throws -> AsyncThrowingStream<GenerationEvent, Error> {
        throw AppleFoundationModelError(message: AppleFoundationModel.availability.explanation)
    }
}
