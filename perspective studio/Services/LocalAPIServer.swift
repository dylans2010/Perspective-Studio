import Foundation
import Network
import SwiftUI
import AppKit

// MARK: - OpenAI Schema Models

struct OpenAIChatMessage: Codable, Sendable {
    let role: String
    let content: String
}

struct OpenAIChatCompletionRequest: Codable, Sendable {
    let model: String?
    let messages: [OpenAIChatMessage]
    let stream: Bool?
    let temperature: Double?
    let max_tokens: Int?
}

struct OpenAIChatCompletionChoice: Codable, Sendable {
    let index: Int
    let message: OpenAIChatMessage
    let finish_reason: String?
}

struct OpenAIUsage: Codable, Sendable {
    let prompt_tokens: Int
    let completion_tokens: Int
    let total_tokens: Int
}

struct OpenAIChatCompletionResponse: Codable, Sendable {
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [OpenAIChatCompletionChoice]
    let usage: OpenAIUsage
}

struct OpenAIDelta: Codable, Sendable {
    let role: String?
    let content: String?
}

struct OpenAIStreamChoice: Codable, Sendable {
    let index: Int
    let delta: OpenAIDelta
    let finish_reason: String?
}

struct OpenAIStreamChunk: Codable, Sendable {
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [OpenAIStreamChoice]
}

struct OpenAIModelItem: Codable, Sendable {
    let id: String
    let object: String
    let created: Int
    let owned_by: String
}

struct OpenAIModelListResponse: Codable, Sendable {
    let object: String
    let data: [OpenAIModelItem]
}

// MARK: - Server Request Log

struct APIServerLog: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let method: String
    let path: String
    let statusCode: Int
    let modelName: String
    let latencyMs: Int
    let tokensGenerated: Int
    let isStream: Bool
    let clientAddress: String
    let errorMessage: String?
}

// MARK: - Local API Server Manager

@Observable
@MainActor
final class LocalAPIServerManager {
    static let shared = LocalAPIServerManager()

    var isRunning: Bool = false
    var port: Int = 1234
    /// Optional bearer token. When set, every request must send
    /// `Authorization: Bearer <token>` — required hygiene before anyone
    /// enables local-network exposure. Stored in UserDefaults like the
    /// app's other non-secret preferences; empty means "no token" (the
    /// loopback-only default posture).
    var apiToken: String = UserDefaults.standard.string(forKey: "localAPIToken") ?? "" {
        didSet { UserDefaults.standard.set(apiToken, forKey: "localAPIToken") }
    }
    var allowLocalNetworkAccess: Bool = false
    var defaultModelID: String = ""
    var availableModels: [String] = []

    var activeConnectionsCount: Int = 0
    var totalRequestsServed: Int = 0
    var logs: [APIServerLog] = []
    var lastError: String? = nil

    private var listener: NWListener?
    private let serverQueue = DispatchQueue(label: "locally.apiserver.queue", qos: .userInitiated)

    var serverURLString: String {
        let host = allowLocalNetworkAccess ? "0.0.0.0" : "127.0.0.1"
        return "http://\(host):\(port)/v1"
    }

    var localhostURLString: String {
        "http://127.0.0.1:\(port)/v1"
    }

    func updateAvailableModels(_ models: [InstalledModel]) {
        self.availableModels = models.map { $0.id }
        if (defaultModelID.isEmpty || !availableModels.contains(defaultModelID)), let first = availableModels.first {
            self.defaultModelID = first
        }
    }

    func startServer() {
        guard !isRunning else { return }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            if !allowLocalNetworkAccess {
                // Default: Bind exclusively to 127.0.0.1 for localhost safety
                parameters.requiredInterfaceType = .loopback
            }

            guard let portEndpoint = NWEndpoint.Port(rawValue: UInt16(port)) else {
                lastError = "Invalid port number: \(port)"
                return
            }

            let newListener = try NWListener(using: parameters, on: portEndpoint)

            newListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        self.lastError = nil
                    case .failed(let error):
                        self.isRunning = false
                        self.lastError = "Server failed: \(error.localizedDescription)"
                    case .cancelled:
                        self.isRunning = false
                    default:
                        break
                    }
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self else { return }
                    self.handleIncomingConnection(connection)
                }
            }

            newListener.start(queue: serverQueue)
            self.listener = newListener
            self.isRunning = true
            self.lastError = nil

        } catch {
            self.isRunning = false
            self.lastError = "Failed to start server: \(error.localizedDescription)"
        }
    }

    func stopServer() {
        listener?.cancel()
        listener = nil
        isRunning = false
        activeConnectionsCount = 0
    }

    func clearLogs() {
        logs.removeAll()
    }

    // MARK: - Connection Handling

    private func handleIncomingConnection(_ connection: NWConnection) {
        activeConnectionsCount += 1
        connection.start(queue: serverQueue)

        readHTTPRequest(from: connection) { [weak self] requestData in
            guard let self else {
                connection.cancel()
                return
            }

            Task {
                await self.processHTTPRequest(requestData: requestData, connection: connection)
                Task { @MainActor in
                    self.activeConnectionsCount = max(0, self.activeConnectionsCount - 1)
                }
            }
        }
    }

    private nonisolated func readHTTPRequest(from connection: NWConnection, completion: @escaping @Sendable (Data) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                completion(data)
            } else if isComplete || error != nil {
                connection.cancel()
            }
        }
    }

    private func processHTTPRequest(requestData: Data, connection: NWConnection) async {
        let startTime = Date.now
        guard let requestString = String(data: requestData, encoding: .utf8) else {
            sendHTTPResponse(status: 400, body: "Bad Request", connection: connection)
            return
        }

        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendHTTPResponse(status: 400, body: "Empty Request Line", connection: connection)
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendHTTPResponse(status: 400, body: "Malformed Request", connection: connection)
            return
        }

        let method = String(parts[0]).uppercased()
        let path = String(parts[1])
        let clientIP = "\(connection.endpoint)"

        // CORS Preflight
        if method == "OPTIONS" {
            sendCORSResponse(connection: connection)
            return
        }

        // Bearer-token auth, when a token is configured.
        if !apiToken.isEmpty {
            let authorization = lines.first { $0.lowercased().hasPrefix("authorization:") } ?? ""
            let presented = authorization
                .dropFirst("authorization:".count)
                .trimmingCharacters(in: .whitespaces)
            guard presented == "Bearer \(apiToken)" else {
                sendJSONError(status: 401, message: "Unauthorized: a valid Bearer token is required.", connection: connection)
                recordLog(method: method, path: path, status: 401, model: "-", latency: Int(Date.now.timeIntervalSince(startTime) * 1000), tokens: 0, stream: false, client: clientIP, error: "401 Unauthorized")
                return
            }
        }

        // GET / or /health
        if method == "GET" && (path == "/" || path == "/health" || path == "/v1") {
            let json = """
            {"status":"ok","app":"Locally","version":"1.0","endpoints":["/v1/models","/v1/chat/completions"]}
            """
            sendJSONResponse(status: 200, json: json, connection: connection)
            recordLog(method: method, path: path, status: 200, model: "-", latency: Int(Date.now.timeIntervalSince(startTime) * 1000), tokens: 0, stream: false, client: clientIP, error: nil)
            return
        }

        // GET /v1/models
        if method == "GET" && path.hasPrefix("/v1/models") {
            let modelsList = self.availableModels.isEmpty ? ["default-local-model"] : self.availableModels
            let items = modelsList.map {
                OpenAIModelItem(id: $0, object: "model", created: Int(Date.now.timeIntervalSince1970), owned_by: "locally")
            }
            let response = OpenAIModelListResponse(object: "list", data: items)
            if let data = try? JSONEncoder().encode(response), let json = String(data: data, encoding: .utf8) {
                sendJSONResponse(status: 200, json: json, connection: connection)
                recordLog(method: method, path: path, status: 200, model: "\(items.count) models", latency: Int(Date.now.timeIntervalSince(startTime) * 1000), tokens: 0, stream: false, client: clientIP, error: nil)
            } else {
                sendHTTPResponse(status: 500, body: "Encoding Error", connection: connection)
            }
            return
        }

        // POST /v1/chat/completions
        if method == "POST" && path.hasPrefix("/v1/chat/completions") {
            // Find Body
            var bodyData = Data()
            if let doubleNewline = requestData.range(of: Data("\r\n\r\n".utf8)) {
                bodyData = requestData.subdata(in: doubleNewline.upperBound..<requestData.count)
            }

            guard let requestPayload = try? JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: bodyData) else {
                sendJSONError(status: 400, message: "Invalid JSON request payload for chat completion.", connection: connection)
                recordLog(method: method, path: path, status: 400, model: "-", latency: Int(Date.now.timeIntervalSince(startTime) * 1000), tokens: 0, stream: false, client: clientIP, error: "JSON Parse Error")
                return
            }

            let requestedModel = requestPayload.model ?? self.defaultModelID
            let isStream = requestPayload.stream ?? false

            // Unknown model names get a proper 404 (OpenAI-style) instead of
            // a 500 from a doomed load attempt. Skipped when we have no
            // catalog yet, so the default model can still be resolved.
            if !availableModels.isEmpty,
               !availableModels.contains(requestedModel),
               requestedModel != defaultModelID,
               requestedModel != "default-local-model" {
                sendJSONError(status: 404, message: "Model '\(requestedModel)' not found. See GET /v1/models.", connection: connection)
                recordLog(method: method, path: path, status: 404, model: requestedModel, latency: Int(Date.now.timeIntervalSince(startTime) * 1000), tokens: 0, stream: isStream, client: clientIP, error: "404 Model Not Found")
                return
            }

            // Ensure model is loaded
            do {
                let currentlyLoaded = await LLMService.shared.currentlyLoadedModelID()
                if currentlyLoaded != requestedModel && !requestedModel.isEmpty && requestedModel != "default" {
                    let stream = try await LLMService.shared.loadModelByID(requestedModel)
                    for try await _ in stream { }
                    try await LLMService.shared.finishLoading()
                }
            } catch {
                sendJSONError(status: 500, message: "Failed to load model \(requestedModel): \(error.localizedDescription)", connection: connection)
                recordLog(method: method, path: path, status: 500, model: requestedModel, latency: Int(Date.now.timeIntervalSince(startTime) * 1000), tokens: 0, stream: isStream, client: clientIP, error: error.localizedDescription)
                return
            }

            let systemPrompt = requestPayload.messages.filter { $0.role == "system" }.map { $0.content }.joined(separator: "\n")
            let promptMessages = requestPayload.messages.map { (role: $0.role, content: $0.content) }
            let lastUserPrompt = requestPayload.messages.last(where: { $0.role == "user" })?.content ?? ""

            if isStream {
                await handleStreamingChatCompletion(
                    requestPayload: requestPayload,
                    modelName: requestedModel,
                    prompt: lastUserPrompt,
                    systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
                    connection: connection,
                    startTime: startTime,
                    clientIP: clientIP
                )
            } else {
                await handleNonStreamingChatCompletion(
                    requestPayload: requestPayload,
                    modelName: requestedModel,
                    prompt: lastUserPrompt,
                    systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
                    connection: connection,
                    startTime: startTime,
                    clientIP: clientIP
                )
            }
            return
        }

        // Unknown endpoint
        sendJSONError(status: 404, message: "Endpoint not found: \(method) \(path)", connection: connection)
        recordLog(method: method, path: path, status: 404, model: "-", latency: Int(Date.now.timeIntervalSince(startTime) * 1000), tokens: 0, stream: false, client: clientIP, error: "404 Not Found")
    }

    // MARK: - Streaming Response Execution

    private func handleStreamingChatCompletion(
        requestPayload: OpenAIChatCompletionRequest,
        modelName: String,
        prompt: String,
        systemPrompt: String?,
        connection: NWConnection,
        startTime: Date,
        clientIP: String
    ) async {
        let headers = """
        HTTP/1.1 200 OK\r
        Content-Type: text/event-stream\r
        Cache-Control: no-cache\r
        Connection: keep-alive\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Headers: *\r
        \r\n
        """
        guard let headerData = headers.data(using: .utf8) else {
            connection.cancel()
            return
        }

        connection.send(content: headerData, completion: .contentProcessed { _ in })

        let completionID = "chatcmpl-\(UUID().uuidString.prefix(12))"
        let created = Int(Date.now.timeIntervalSince1970)
        var tokenCount = 0

        do {
            let stream = try await LLMService.shared.generateSinglePrompt(
                prompt: prompt,
                systemPrompt: systemPrompt,
                temperature: requestPayload.temperature
            )

            // Initial role chunk
            let initialChunk = OpenAIStreamChunk(
                id: completionID,
                object: "chat.completion.chunk",
                created: created,
                model: modelName,
                choices: [OpenAIStreamChoice(index: 0, delta: OpenAIDelta(role: "assistant", content: nil), finish_reason: nil)]
            )
            sendSSEChunk(initialChunk, connection: connection)

            // Stream tokens
            for await token in stream {
                tokenCount += 1
                let chunk = OpenAIStreamChunk(
                    id: completionID,
                    object: "chat.completion.chunk",
                    created: created,
                    model: modelName,
                    choices: [OpenAIStreamChoice(index: 0, delta: OpenAIDelta(role: nil, content: token), finish_reason: nil)]
                )
                sendSSEChunk(chunk, connection: connection)
            }

            // Finish chunk
            let finishChunk = OpenAIStreamChunk(
                id: completionID,
                object: "chat.completion.chunk",
                created: created,
                model: modelName,
                choices: [OpenAIStreamChoice(index: 0, delta: OpenAIDelta(role: nil, content: nil), finish_reason: "stop")]
            )
            sendSSEChunk(finishChunk, connection: connection)

            // SSE [DONE]
            if let doneData = "data: [DONE]\n\n".data(using: .utf8) {
                connection.send(content: doneData, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }

            let latency = Int(Date.now.timeIntervalSince(startTime) * 1000)
            recordLog(method: "POST", path: "/v1/chat/completions", status: 200, model: modelName, latency: latency, tokens: tokenCount, stream: true, client: clientIP, error: nil)

        } catch {
            let latency = Int(Date.now.timeIntervalSince(startTime) * 1000)
            recordLog(method: "POST", path: "/v1/chat/completions", status: 500, model: modelName, latency: latency, tokens: tokenCount, stream: true, client: clientIP, error: error.localizedDescription)
            connection.cancel()
        }
    }

    private func sendSSEChunk(_ chunk: OpenAIStreamChunk, connection: NWConnection) {
        guard let data = try? JSONEncoder().encode(chunk),
              let json = String(data: data, encoding: .utf8) else { return }
        let payload = "data: \(json)\n\n"
        if let sseData = payload.data(using: .utf8) {
            connection.send(content: sseData, completion: .contentProcessed { _ in })
        }
    }

    // MARK: - Non-Streaming Response Execution

    private func handleNonStreamingChatCompletion(
        requestPayload: OpenAIChatCompletionRequest,
        modelName: String,
        prompt: String,
        systemPrompt: String?,
        connection: NWConnection,
        startTime: Date,
        clientIP: String
    ) async {
        let completionID = "chatcmpl-\(UUID().uuidString.prefix(12))"
        let created = Int(Date.now.timeIntervalSince1970)
        var fullText = ""
        var tokenCount = 0

        do {
            let stream = try await LLMService.shared.generateSinglePrompt(
                prompt: prompt,
                systemPrompt: systemPrompt,
                temperature: requestPayload.temperature
            )

            for await token in stream {
                fullText += token
                tokenCount += 1
            }

            let response = OpenAIChatCompletionResponse(
                id: completionID,
                object: "chat.completion",
                created: created,
                model: modelName,
                choices: [
                    OpenAIChatCompletionChoice(
                        index: 0,
                        message: OpenAIChatMessage(role: "assistant", content: fullText),
                        finish_reason: "stop"
                    )
                ],
                usage: OpenAIUsage(
                    prompt_tokens: prompt.split(separator: " ").count,
                    completion_tokens: tokenCount,
                    total_tokens: prompt.split(separator: " ").count + tokenCount
                )
            )

            if let data = try? JSONEncoder().encode(response), let json = String(data: data, encoding: .utf8) {
                sendJSONResponse(status: 200, json: json, connection: connection)
                let latency = Int(Date.now.timeIntervalSince(startTime) * 1000)
                recordLog(method: "POST", path: "/v1/chat/completions", status: 200, model: modelName, latency: latency, tokens: tokenCount, stream: false, client: clientIP, error: nil)
            } else {
                sendHTTPResponse(status: 500, body: "Encoding error", connection: connection)
            }

        } catch {
            let latency = Int(Date.now.timeIntervalSince(startTime) * 1000)
            sendJSONError(status: 500, message: error.localizedDescription, connection: connection)
            recordLog(method: "POST", path: "/v1/chat/completions", status: 500, model: modelName, latency: latency, tokens: 0, stream: false, client: clientIP, error: error.localizedDescription)
        }
    }

    // MARK: - HTTP Network Helpers

    private func sendJSONResponse(status: Int, json: String, connection: NWConnection) {
        let bodyData = json.data(using: .utf8) ?? Data()
        let headers = """
        HTTP/1.1 \(status) OK\r
        Content-Type: application/json\r
        Content-Length: \(bodyData.count)\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Headers: *\r
        Connection: close\r
        \r\n
        """
        var responseData = headers.data(using: .utf8) ?? Data()
        responseData.append(bodyData)
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendJSONError(status: Int, message: String, connection: NWConnection) {
        let json = """
        {"error":{"message":"\(message.replacingOccurrences(of: "\"", with: "\\\""))","type":"server_error","code":\(status)}}
        """
        sendJSONResponse(status: status, json: json, connection: connection)
    }

    private func sendCORSResponse(connection: NWConnection) {
        let headers = """
        HTTP/1.1 200 OK\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Methods: GET, POST, OPTIONS\r
        Access-Control-Allow-Headers: Content-Type, Authorization\r
        Content-Length: 0\r
        \r\n
        """
        if let data = headers.data(using: .utf8) {
            connection.send(content: data, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func sendHTTPResponse(status: Int, body: String, connection: NWConnection) {
        let bodyData = body.data(using: .utf8) ?? Data()
        let headers = """
        HTTP/1.1 \(status) OK\r
        Content-Type: text/plain\r
        Content-Length: \(bodyData.count)\r
        Connection: close\r
        \r\n
        """
        var responseData = headers.data(using: .utf8) ?? Data()
        responseData.append(bodyData)
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func recordLog(
        method: String,
        path: String,
        status: Int,
        model: String,
        latency: Int,
        tokens: Int,
        stream: Bool,
        client: String,
        error: String?
    ) {
        totalRequestsServed += 1
        let log = APIServerLog(
            timestamp: Date.now,
            method: method,
            path: path,
            statusCode: status,
            modelName: model,
            latencyMs: latency,
            tokensGenerated: tokens,
            isStream: stream,
            clientAddress: client,
            errorMessage: error
        )
        logs.insert(log, at: 0)
        if logs.count > 100 {
            logs.removeLast()
        }
    }
}
