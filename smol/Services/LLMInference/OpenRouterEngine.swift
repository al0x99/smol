import Foundation
import Network
import os

/// OpenAI-compatible cloud LLM backend (OpenRouter, Together, Groq, OpenAI, etc.)
/// Streams responses via Server-Sent Events (SSE)
class OpenRouterEngine: LLMInferenceEngine, @unchecked Sendable {

    // MARK: - Properties

    let backendName = "Cloud"

    private(set) var isModelLoaded = false
    private(set) var loadedModelPath: URL?

    private var apiKey: String?
    private var baseURL: URL
    private var modelID: String
    private var session: URLSession
    private var shouldCancel = false

    // Network monitoring
    private let pathMonitor = NWPathMonitor()
    private var isNetworkAvailable = true

    // MARK: - SSE Types

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
        let stream: Bool
        let temperature: Float?
        let top_p: Float?
        let max_tokens: Int?
        let stop: [String]?
    }

    private struct ChatMessage: Encodable {
        let role: String
        let content: String
    }

    private struct StreamChunk: Decodable {
        let choices: [StreamChoice]?
        let usage: Usage?

        struct StreamChoice: Decodable {
            let delta: Delta?
            let finish_reason: String?
        }

        struct Delta: Decodable {
            let content: String?
        }

        struct Usage: Decodable {
            let prompt_tokens: Int?
            let completion_tokens: Int?
            let total_tokens: Int?
        }
    }

    private struct CompletionResponse: Decodable {
        let choices: [Choice]
        let usage: Usage?

        struct Choice: Decodable {
            let message: ResponseMessage
            let finish_reason: String?
        }

        struct ResponseMessage: Decodable {
            let content: String?
        }

        struct Usage: Decodable {
            let prompt_tokens: Int?
            let completion_tokens: Int?
            let total_tokens: Int?
        }
    }

    private struct APIError: Decodable {
        let error: ErrorDetail
        struct ErrorDetail: Decodable {
            let message: String
            let code: Int?
        }
    }

    // MARK: - Initialization

    init() {
        self.baseURL = URL(string: KeychainHelper.providerBaseURL)!
        self.modelID = KeychainHelper.modelID
        self.apiKey = KeychainHelper.apiKey

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        self.session = URLSession(configuration: config)

        // Monitor network
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.isNetworkAvailable = path.status == .satisfied
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.whitepaper.smol.network"))

        isModelLoaded = apiKey != nil
    }

    deinit {
        pathMonitor.cancel()
    }

    // MARK: - Configuration

    /// Reload configuration from Keychain
    func reloadConfig() {
        apiKey = KeychainHelper.apiKey
        if let urlString = KeychainHelper.load(account: KeychainHelper.providerURLAccount),
           let url = URL(string: urlString) {
            baseURL = url
        }
        modelID = KeychainHelper.modelID
        isModelLoaded = apiKey != nil
    }

    // MARK: - LLMInferenceEngine Protocol

    func loadModel(at path: URL, config: LLMConfig) async throws {
        reloadConfig()

        guard let key = apiKey, !key.isEmpty else {
            throw LLMError.modelLoadFailed("No API key configured")
        }

        guard isNetworkAvailable else {
            throw LLMError.backendNotAvailable("No network connection")
        }

        isModelLoaded = true
    }

    func unloadModel() {
        shouldCancel = true
        isModelLoaded = false
    }

    func generate(prompt: String, config: GenerationConfig) async throws -> AsyncThrowingStream<String, Error> {
        guard isModelLoaded, let key = apiKey else {
            throw LLMError.modelNotLoaded
        }

        guard isNetworkAvailable else {
            throw LLMError.backendNotAvailable("No network connection")
        }

        // Build messages
        var messages: [ChatMessage] = []
        if let systemPrompt = config.systemPrompt {
            messages.append(ChatMessage(role: "system", content: systemPrompt))
        }
        messages.append(ChatMessage(role: "user", content: prompt))

        let requestBody = ChatRequest(
            model: modelID,
            messages: messages,
            stream: true,
            temperature: config.temperature,
            top_p: config.topP,
            max_tokens: config.maxTokens,
            stop: config.stopSequences.isEmpty ? nil : config.stopSequences
        )

        let urlRequest = try buildURLRequest(body: requestBody, apiKey: key)
        shouldCancel = false

        return AsyncThrowingStream { [weak self] continuation in
            guard let self else {
                continuation.finish(throwing: LLMError.generationFailed("Engine deallocated"))
                return
            }

            Task {
                do {
                    let (bytes, response) = try await self.session.bytes(for: urlRequest)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: LLMError.generationFailed("Invalid response"))
                        return
                    }

                    if httpResponse.statusCode != 200 {
                        try self.handleHTTPError(statusCode: httpResponse.statusCode, bytes: bytes)
                    }

                    // Parse SSE stream
                    for try await line in bytes.lines {
                        if self.shouldCancel { break }

                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))

                        if payload == "[DONE]" { break }

                        guard let data = payload.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
                              let content = chunk.choices?.first?.delta?.content else {
                            continue
                        }

                        continuation.yield(content)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func generateComplete(prompt: String, config: GenerationConfig) async throws -> LLMResponse {
        let startTime = Date()
        var fullText = ""
        var tokenCount = 0

        for try await token in try await generate(prompt: prompt, config: config) {
            fullText += token
            tokenCount += 1
        }

        let elapsed = Date().timeIntervalSince(startTime)

        return LLMResponse(
            text: fullText,
            tokenCount: tokenCount,
            generationTime: elapsed,
            tokensPerSecond: elapsed > 0 ? Double(tokenCount) / elapsed : 0,
            finishReason: .complete
        )
    }

    func cancelGeneration() {
        shouldCancel = true
    }

    // MARK: - Helpers

    private func buildURLRequest<T: Encodable>(body: T, apiKey: String) throws -> URLRequest {
        let endpoint = baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("smol", forHTTPHeaderField: "X-Title")
        request.setValue("https://github.com/al0x99/smol", forHTTPHeaderField: "HTTP-Referer")
        return request
    }

    private func handleHTTPError(statusCode: Int, bytes: URLSession.AsyncBytes) throws -> Never {
        switch statusCode {
        case 401:
            throw LLMError.modelLoadFailed("Invalid API key")
        case 429:
            throw LLMError.generationFailed("Rate limited — try again later")
        case 402:
            throw LLMError.generationFailed("Insufficient credits")
        default:
            throw LLMError.generationFailed("API error (HTTP \(statusCode))")
        }
    }

    // MARK: - Static

    static var isAvailable: Bool {
        KeychainHelper.hasAPIKey
    }

    /// Validate API key by making a lightweight request
    static func validateAPIKey(_ key: String, baseURL: String) async -> (valid: Bool, message: String) {
        guard let url = URL(string: baseURL)?.appendingPathComponent("models") else {
            return (false, "Invalid URL")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return (false, "Invalid response")
            }

            switch httpResponse.statusCode {
            case 200: return (true, "Connected")
            case 401: return (false, "Invalid API key")
            case 403: return (false, "Access denied")
            default: return (false, "HTTP \(httpResponse.statusCode)")
            }
        } catch {
            return (false, "Connection failed: \(error.localizedDescription)")
        }
    }
}
