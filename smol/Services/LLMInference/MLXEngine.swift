import Foundation
import os

#if canImport(MLXLLM)
import MLXLLM
import MLXLMCommon
import MLX
import Tokenizers
#endif

/// Inference engine based on MLX (Apple Silicon optimized)
/// Uses mlx-swift-lm for real on-device LLM inference
/// Supports SafeTensors/MLX format models from HuggingFace
class MLXEngine: LLMInferenceEngine, @unchecked Sendable {

    // MARK: - Properties

    let backendName = "MLX"

    private(set) var isModelLoaded = false
    private(set) var loadedModelPath: URL?

    #if canImport(MLXLLM)
    private var modelContainer: ModelContainer?
    #endif

    private var currentConfig: LLMConfig?

    // Generation state
    private var shouldCancel = false
    private let stateLock = NSLock()

    // MARK: - Static

    /// Check if MLX is available (requires Apple Silicon + mlx-swift package)
    static var isAvailable: Bool {
        #if canImport(MLXLLM)
        return isAppleSilicon
        #else
        return false
        #endif
    }

    /// Human-readable availability status
    static var availabilityStatus: String {
        #if canImport(MLXLLM)
        if isAppleSilicon {
            return "Available (Apple Silicon)"
        }
        return "Requires Apple Silicon"
        #else
        return "MLX package not installed"
        #endif
    }

    private static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    // MARK: - Initialization

    init() {}

    deinit {
        unloadModel()
    }

    // MARK: - LLMInferenceEngine Protocol

    func loadModel(at path: URL, config: LLMConfig) async throws {
        if isModelLoaded {
            unloadModel()
        }

        guard FileManager.default.fileExists(atPath: path.path) else {
            throw LLMError.modelLoadFailed("File not found: \(path.path)")
        }

        currentConfig = config

        #if canImport(MLXLLM)
        SmolLog.ai.info("MLXEngine: Loading model from \(path.lastPathComponent, privacy: .public)")

        do {
            // MLX models are directories containing config.json, weights, tokenizer
            let modelDirectory: URL
            if path.hasDirectoryPath || FileManager.default.fileExists(atPath: path.appendingPathComponent("config.json").path) {
                modelDirectory = path
            } else {
                modelDirectory = path.deletingLastPathComponent()
            }

            let configuration = ModelConfiguration(directory: modelDirectory)
            modelContainer = try await MLXLLM.loadModelContainer(configuration: configuration) { progress in
                SmolLog.ai.debug("MLXEngine: Load progress \(progress.fractionCompleted * 100, format: .fixed(precision: 0))%")
            }

            isModelLoaded = true
            loadedModelPath = path
            SmolLog.ai.info("MLXEngine: Model loaded successfully")
        } catch {
            SmolLog.ai.error("MLXEngine: Failed to load model: \(error.localizedDescription, privacy: .public)")
            throw LLMError.modelLoadFailed(error.localizedDescription)
        }
        #else
        // Without MLXLLM package, simulate loading for demo
        SmolLog.ai.debug("MLXEngine: Demo mode — MLX package not installed")
        isModelLoaded = true
        loadedModelPath = path
        #endif
    }

    func unloadModel() {
        shouldCancel = true

        #if canImport(MLXLLM)
        modelContainer = nil
        #endif

        isModelLoaded = false
        loadedModelPath = nil
        currentConfig = nil
    }

    func generate(prompt: String, config: GenerationConfig) async throws -> AsyncThrowingStream<String, Error> {
        guard isModelLoaded else {
            throw LLMError.modelNotLoaded
        }

        return AsyncThrowingStream { [weak self] continuation in
            guard let self else {
                continuation.finish(throwing: LLMError.generationFailed("Engine deallocated"))
                return
            }

            self.stateLock.lock()
            self.shouldCancel = false
            self.stateLock.unlock()

            Task {
                do {
                    try await self.streamGenerate(prompt: prompt, config: config) { token in
                        continuation.yield(token)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func generateComplete(prompt: String, config: GenerationConfig) async throws -> LLMResponse {
        guard isModelLoaded else {
            throw LLMError.modelNotLoaded
        }

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
            finishReason: shouldCancel ? .maxTokens : .complete
        )
    }

    /// Cancel generation in progress
    func cancelGeneration() {
        stateLock.lock()
        shouldCancel = true
        stateLock.unlock()
    }

    // MARK: - Private Implementation

    private func streamGenerate(prompt: String, config: GenerationConfig, onToken: @escaping (String) -> Void) async throws {
        // Build prompt with system message
        let fullPrompt: String
        if let systemPrompt = config.systemPrompt {
            fullPrompt = "<|system|>\n\(systemPrompt)</s>\n<|user|>\n\(prompt)</s>\n<|assistant|>\n"
        } else {
            fullPrompt = prompt
        }

        #if canImport(MLXLLM)
        guard let container = modelContainer else {
            throw LLMError.modelNotLoaded
        }

        let result = try await container.perform { (model, tokenizer) in
            let tokens = tokenizer.encode(text: fullPrompt)
            let inputArray = MLXArray(tokens)

            var generatedTokens = 0

            for token in try model.generate(input: inputArray, parameters: .init(
                temperature: config.temperature,
                topP: config.topP,
                repetitionPenalty: config.repeatPenalty
            )) {
                if self.shouldCancel || generatedTokens >= config.maxTokens { break }

                let tokenText = tokenizer.decode(tokens: [token.item(Int32.self)])
                onToken(tokenText)
                generatedTokens += 1
            }

            return generatedTokens
        }

        SmolLog.ai.debug("MLXEngine: Generated \(result) tokens")
        #else
        // Demo mode — simulated response
        let demoResponse = "[MLX Demo] Model loaded from \(loadedModelPath?.lastPathComponent ?? "unknown"). " +
            "To enable real inference, add mlx-swift-examples as an SPM dependency. " +
            "Query: \"\(prompt.prefix(80))...\""

        for word in demoResponse.split(separator: " ") {
            if shouldCancel { break }
            onToken(String(word) + " ")
            try await Task.sleep(nanoseconds: 20_000_000)  // 20ms per token
        }
        #endif
    }

    // MARK: - Utilities

    /// Estimate memory requirements for a model
    static func estimateMemoryRequirements(for modelPath: URL) -> UInt64 {
        // MLX uses unified memory — estimate based on file size
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: modelPath.path),
              let size = attrs[.size] as? UInt64 else {
            return 0
        }
        // For quantized models, runtime memory ~= file size
        return size
    }

    /// Check if the device has optimal MLX support
    static var hasOptimalMLXSupport: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }
}
