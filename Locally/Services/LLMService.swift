import Foundation

#if canImport(MLXLLM)
import MLXLLM
import MLXVLM
import MLXLMCommon

actor LLMService {
    static let shared = LLMService()

    private var modelContainer: ModelContainer?
    private var chatSession: ChatSession?
    private var isCancelled = false
    private var isVLM = false
    private var isLoading = false
    private var currentModelID: String?

    func currentlyLoadedModelID() -> String? {
        currentModelID
    }

    func isLoaded() -> Bool {
        modelContainer != nil
    }

    func loadModelByID(_ id: String, isVideoModel: Bool = false) throws -> AsyncThrowingStream<Double, Error> {
        // Guard against reentrancy — cancel any in-flight load
        if isLoading {
            isCancelled = true
        }
        isCancelled = false
        isLoading = true
        isVLM = isVideoModel

        // Unload previous model to free memory before loading new one
        modelContainer = nil
        chatSession = nil
        currentModelID = nil

        return AsyncThrowingStream { continuation in
            Task {
                let configuration = ModelConfiguration(id: id)

                do {
                    let factory: ModelFactory = isVideoModel
                        ? VLMModelFactory.shared
                        : LLMModelFactory.shared

                    let container = try await factory.loadContainer(
                        configuration: configuration
                    ) { progress in
                        continuation.yield(progress.fractionCompleted)
                    }
                    self.modelContainer = container
                    self.chatSession = ChatSession(container)
                    self.currentModelID = id
                    self.isLoading = false
                    continuation.finish()
                } catch {
                    self.isLoading = false
                    self.currentModelID = nil
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func generateSinglePrompt(
        prompt: String,
        systemPrompt: String? = nil,
        temperature: Double? = nil
    ) throws -> AsyncStream<String> {
        guard let container = modelContainer else {
            throw LLMError.modelNotLoaded
        }

        // The system prompt becomes the session's `instructions`, which
        // MLXLMCommon prepends as a real system message. This used to create
        // a bare `ChatSession(container)` and silently discard `systemPrompt`
        // (and `temperature`) — every caller that passed tools, system
        // assets, custom prompts, or skills believed the model had seen
        // them, and it never had.
        let session = ChatSession(
            container,
            instructions: systemPrompt,
            generateParameters: Self.generateParameters(temperature: temperature)
        )
        isCancelled = false

        return AsyncStream { continuation in
            Task {
                do {
                    let stream = session.streamResponse(to: prompt, images: [], videos: [])
                    for try await token in stream {
                        if self.isCancelled { break }
                        continuation.yield(token)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish()
                }
            }
        }
    }

    func finishLoading() async throws {
        // Model is already loaded after loadModelByID completes
    }

    func resetSession() {
        if let container = modelContainer {
            chatSession = ChatSession(container)
        }
    }

    /// Builds MLX generation parameters from `GenerationDefaults`:
    /// the caller's temperature (or the conversational fallback when
    /// none was supplied — previously `nil` silently meant the engine's
    /// compiled-in default), top-p, and a hard maximum output-token cap
    /// so no generation can ramble until the context window fills.
    /// Stop behavior comes from the model's own EOS / chat-template
    /// end-of-turn token, which MLX applies itself; there is no
    /// stop-string API to configure and none is invented.
    private static func generateParameters(temperature: Double?, maxTokens: Int = GenerationDefaults.maxChatOutputTokens) -> GenerateParameters {
        GenerateParameters(
            maxTokens: maxTokens,
            temperature: Float(GenerationDefaults.temperature(temperature)),
            topP: GenerationDefaults.topP
        )
    }

    func generate(
        messages: [(role: String, content: String)],
        videoURLs: [URL] = [],
        imageURLs: [URL] = [],
        systemPrompt: String? = nil,
        temperature: Double? = nil
    ) throws -> AsyncStream<String> {
        guard let container = modelContainer else {
            throw LLMError.modelNotLoaded
        }

        isCancelled = false

        // Rebuild the session for every turn from the caller's messages:
        //
        // - `systemPrompt` is passed as the session's `instructions`, so it
        //   is actually sent as a system message. The old implementation
        //   accepted the parameter and never used it, which is why the model
        //   never saw custom prompts, skills, tools, or system assets.
        // - History is rehydrated from `messages` instead of relying on a
        //   long-lived session's internal state, so the context matches the
        //   saved conversation (and survives relaunch / model reload).
        //   Assistant turns are stripped of <thinking> blocks — reasoning is
        //   for the user to read, not tokens to re-feed the model.
        // - System entries already contained in `systemPrompt` (the
        //   conversation prompt travels inside the built prompt) are not
        //   duplicated as history.
        guard let lastUserIndex = messages.lastIndex(where: { $0.role == "user" }) else {
            throw LLMError.modelNotLoaded
        }
        let lastUserMessage = messages[lastUserIndex].content

        var history: [Chat.Message] = []
        for entry in messages[..<lastUserIndex] {
            let content = entry.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            switch entry.role {
            case "system":
                if let systemPrompt, systemPrompt.contains(entry.content) { continue }
                history.append(.system(entry.content))
            case "assistant":
                let visible = ThinkingContentParser.visibleContent(of: entry.content)
                if !visible.isEmpty { history.append(.assistant(visible)) }
            case "user":
                history.append(.user(entry.content))
            default:
                continue
            }
        }

        let session = ChatSession(
            container,
            instructions: systemPrompt,
            history: history,
            generateParameters: Self.generateParameters(temperature: temperature)
        )
        chatSession = session

        let videos: [UserInput.Video] = videoURLs.map { .url($0) }
        // Images reach the engine only on this path, and callers gate it on
        // the loaded model actually being a vision model.
        let images: [UserInput.Image] = imageURLs.map { .url($0) }

        return AsyncStream { continuation in
            Task {
                do {
                    let stream = session.streamResponse(to: lastUserMessage, images: images, videos: videos)
                    for try await token in stream {
                        if self.isCancelled { break }
                        continuation.yield(token)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish()
                }
            }
        }
    }

    func summarize(prompt: String) async throws -> String {
        guard let container = modelContainer else {
            throw LLMError.modelNotLoaded
        }

        // Use a temporary session so we do not pollute the main chat history
        let session = ChatSession(container)
        var result = ""
        let stream = session.streamResponse(to: prompt, images: [], videos: [])
        for try await token in stream {
            result += token
        }
        return result
    }

    func cancel() {
        isCancelled = true
    }

    func unloadModel() {
        modelContainer = nil
        chatSession = nil
        currentModelID = nil
        isVLM = false
        isLoading = false
    }
}

#else

actor LLMService {
    static let shared = LLMService()

    private var isCancelled = false

    func loadModelByID(_ id: String, isVideoModel: Bool = false) throws -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { $0.finish(throwing: LLMError.modelNotLoaded) }
    }

    func finishLoading() async throws {}

    func generate(
        messages: [(role: String, content: String)],
        videoURLs: [URL] = [],
        imageURLs: [URL] = [],
        systemPrompt: String? = nil,
        temperature: Double? = nil
    ) throws -> AsyncStream<String> {
        throw LLMError.modelNotLoaded
    }

    func summarize(prompt: String) async throws -> String {
        throw LLMError.modelNotLoaded
    }

    func currentlyLoadedModelID() -> String? { nil }
    func isLoaded() -> Bool { false }

    func generateSinglePrompt(
        prompt: String,
        systemPrompt: String? = nil,
        temperature: Double? = nil
    ) throws -> AsyncStream<String> {
        throw LLMError.modelNotLoaded
    }

    func cancel() { isCancelled = true }
    func resetSession() {}
    func unloadModel() {}
}

#endif

enum LLMError: LocalizedError {
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: "No model is loaded. Please download and load a model first."
        }
    }
}
