import Foundation
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Foundation Models engine (macOS 26+)
/// Free on-device AI using Apple's built-in ~3B language model
/// Zero dependencies, zero data sent externally, runs on Neural Engine
class FoundationModelEngine: LLMInferenceEngine, @unchecked Sendable {

    // MARK: - Properties

    let backendName = "Apple AI"

    private(set) var isModelLoaded = false
    private(set) var loadedModelPath: URL?

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private var session: LanguageModelSession?

    /// Store last used instructions to recreate session if needed
    private var lastInstructions: String?
    #endif

    private var shouldCancel = false
    private let stateLock = NSLock()

    // MARK: - Static

    /// Check if Apple Foundation Models are available (macOS 26+ with Apple Silicon + Apple Intelligence enabled)
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        return false
        #else
        return false
        #endif
    }

    /// Human-readable availability status
    static var availabilityStatus: String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return "Available"
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return "Device not eligible"
                case .appleIntelligenceNotEnabled:
                    return "Apple Intelligence not enabled"
                case .modelNotReady:
                    return "Model downloading..."
                @unknown default:
                    return "Unavailable"
                }
            }
        }
        return "Requires macOS 26"
        #else
        return "Requires macOS 26 SDK"
        #endif
    }

    // MARK: - LLMInferenceEngine Protocol

    func loadModel(at path: URL, config: LLMConfig) async throws {
        // Foundation Models doesn't need a model file — it uses the system model
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard SystemLanguageModel.default.availability == .available else {
                throw LLMError.backendNotAvailable("Apple AI: \(Self.availabilityStatus)")
            }
            session = LanguageModelSession()
            isModelLoaded = true
            loadedModelPath = nil
            SmolLog.ai.info("FoundationModelEngine: Apple AI session initialized")
            return
        }
        #endif

        throw LLMError.backendNotAvailable("Apple Foundation Models requires macOS 26+")
    }

    func unloadModel() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            session = nil
            lastInstructions = nil
        }
        #endif
        isModelLoaded = false
        loadedModelPath = nil
    }

    func generate(prompt: String, config: GenerationConfig) async throws -> AsyncThrowingStream<String, Error> {
        guard isModelLoaded else {
            throw LLMError.modelNotLoaded
        }

        stateLock.withLock { shouldCancel = false }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            // Create a new session with instructions if system prompt changed
            let instructions = config.systemPrompt
            if instructions != lastInstructions {
                session = LanguageModelSession(instructions: instructions)
                lastInstructions = instructions
            }

            guard let session else {
                throw LLMError.modelNotLoaded
            }

            let stream = session.streamResponse(to: prompt)

            return AsyncThrowingStream { [weak self] continuation in
                Task {
                    var lastContent = ""
                    do {
                        for try await snapshot in stream {
                            guard self?.shouldCancel != true else { break }
                            // Emit only the new part (delta)
                            let currentContent = snapshot.content
                            if currentContent.count > lastContent.count {
                                let delta = String(currentContent.dropFirst(lastContent.count))
                                continuation.yield(delta)
                                lastContent = currentContent
                            }
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
        #endif

        throw LLMError.backendNotAvailable("Apple Foundation Models requires macOS 26+")
    }

    func generateComplete(prompt: String, config: GenerationConfig) async throws -> LLMResponse {
        guard isModelLoaded else {
            throw LLMError.modelNotLoaded
        }

        let startTime = Date()

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            // Create a new session with instructions if system prompt changed
            let instructions = config.systemPrompt
            if instructions != lastInstructions {
                session = LanguageModelSession(instructions: instructions)
                lastInstructions = instructions
            }

            guard let session else {
                throw LLMError.modelNotLoaded
            }

            let response = try await session.respond(to: prompt)
            let text = response.content
            let elapsed = Date().timeIntervalSince(startTime)

            // Approximate token count (words + punctuation)
            let tokenCount = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count

            return LLMResponse(
                text: text,
                tokenCount: tokenCount,
                generationTime: elapsed,
                tokensPerSecond: elapsed > 0 ? Double(tokenCount) / elapsed : 0,
                finishReason: .complete
            )
        }
        #endif

        throw LLMError.backendNotAvailable("Apple Foundation Models requires macOS 26+")
    }

    /// Cancel generation in progress
    func cancelGeneration() {
        stateLock.withLock { shouldCancel = true }
    }

    /// Initialize the engine if Foundation Models are available (called at startup)
    func initializeIfAvailable() async -> Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard SystemLanguageModel.default.availability == .available else {
                SmolLog.ai.info("FoundationModelEngine: Apple AI not available — \(Self.availabilityStatus)")
                return false
            }

            session = LanguageModelSession()
            isModelLoaded = true
            SmolLog.ai.info("FoundationModelEngine: Auto-initialized Apple AI")
            return true
        }
        #endif
        return false
    }
}
