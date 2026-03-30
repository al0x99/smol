import Foundation

/// Inference engine based on llama.cpp
/// Supports GGUF/GGML models
/// Requires llama.cpp Swift bindings (llama.swift package)
class LlamaCppEngine: LLMInferenceEngine, @unchecked Sendable {

    // MARK: - Properties

    let backendName = "llama.cpp"

    private(set) var isModelLoaded = false
    private(set) var loadedModelPath: URL?

    // llama.cpp context e model handles
    private var modelHandle: OpaquePointer?
    private var contextHandle: OpaquePointer?
    private var currentConfig: LLMConfig?

    // Generation state (thread-safe access)
    private var isGeneratingFlag = false
    private var shouldCancel = false
    private let stateLock = NSLock()

    // MARK: - Static

    /// Check if llama.cpp is available
    static var isAvailable: Bool {
        #if canImport(llama)
        return true
        #else
        return false
        #endif
    }

    // MARK: - Initialization

    init() {
        // Initialize llama.cpp backend
        initializeLlamaCpp()
    }

    deinit {
        unloadModel()
    }

    // MARK: - LLMInferenceEngine Protocol

    func loadModel(at path: URL, config: LLMConfig) async throws {
        // Unload previous if present
        if isModelLoaded {
            unloadModel()
        }

        guard FileManager.default.fileExists(atPath: path.path) else {
            throw LLMError.modelLoadFailed("File non trovato: \(path.path)")
        }

        // Verify extension
        let ext = path.pathExtension.lowercased()
        guard ext == "gguf" || ext == "ggml" else {
            throw LLMError.invalidModelFormat
        }

        currentConfig = config

        // Load the model in background
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: LLMError.modelLoadFailed("Engine deallocato"))
                    return
                }

                do {
                    try self.loadModelSync(at: path, config: config)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func unloadModel() {
        shouldCancel = true

        // Free context
        if let ctx = contextHandle {
            llama_free(ctx)
            contextHandle = nil
        }

        // Free model
        if let model = modelHandle {
            llama_free_model(model)
            modelHandle = nil
        }

        isModelLoaded = false
        loadedModelPath = nil
        currentConfig = nil
    }

    func generate(prompt: String, config: GenerationConfig) async throws -> AsyncThrowingStream<String, Error> {
        guard isModelLoaded, contextHandle != nil else {
            throw LLMError.modelNotLoaded
        }

        return AsyncThrowingStream { [weak self] continuation in
            guard let self = self else {
                continuation.finish(throwing: LLMError.generationFailed("Engine deallocato"))
                return
            }

            self.stateLock.lock()
            self.isGeneratingFlag = true
            self.shouldCancel = false
            self.stateLock.unlock()

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.generateStreaming(prompt: prompt, config: config) { token in
                        continuation.yield(token)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }

                self.stateLock.lock()
                self.isGeneratingFlag = false
                self.stateLock.unlock()
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
            finishReason: .complete
        )
    }

    /// Cancel generation in progress
    func cancelGeneration() {
        shouldCancel = true
    }

    // MARK: - Private Implementation

    private func initializeLlamaCpp() {
        // Initialize llama.cpp backend
        llama_backend_init()
    }

    private func loadModelSync(at path: URL, config: LLMConfig) throws {
        // Model parameters
        var modelParams = llama_model_default_params()
        modelParams.use_mmap = config.useMmap
        modelParams.use_mlock = config.useMlock

        // GPU layers (-1 = all)
        if config.gpuLayers >= 0 {
            modelParams.n_gpu_layers = Int32(config.gpuLayers)
        } else {
            modelParams.n_gpu_layers = 99  // All layers on GPU
        }

        // Load model
        guard let model = llama_load_model_from_file(path.path, modelParams) else {
            throw LLMError.modelLoadFailed("llama_load_model_from_file fallito")
        }
        modelHandle = model

        // Create context
        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = UInt32(config.contextLength)
        ctxParams.n_batch = UInt32(config.batchSize)
        ctxParams.n_threads = config.threads > 0 ? UInt32(config.threads) : UInt32(Foundation.ProcessInfo.processInfo.processorCount)
        ctxParams.n_threads_batch = ctxParams.n_threads

        guard let ctx = llama_new_context_with_model(model, ctxParams) else {
            llama_free_model(model)
            modelHandle = nil
            throw LLMError.modelLoadFailed("llama_new_context_with_model fallito")
        }
        contextHandle = ctx

        isModelLoaded = true
        loadedModelPath = path
    }

    private func generateStreaming(prompt: String, config: GenerationConfig, onToken: @escaping (String) -> Void) throws {
        guard let ctx = contextHandle, let model = modelHandle else {
            throw LLMError.modelNotLoaded
        }

        // Prepare full prompt with system prompt
        var fullPrompt = ""
        if let systemPrompt = config.systemPrompt {
            fullPrompt = "<|system|>\n\(systemPrompt)</s>\n<|user|>\n\(prompt)</s>\n<|assistant|>\n"
        } else {
            fullPrompt = prompt
        }

        // Tokenize
        let tokens = tokenize(text: fullPrompt, model: model)
        guard !tokens.isEmpty else {
            throw LLMError.generationFailed("Tokenizzazione fallita")
        }

        // Evaluate prompt
        var batch = llama_batch_init(Int32(tokens.count), 0, 1)
        defer { llama_batch_free(batch) }

        for (i, token) in tokens.enumerated() {
            llama_batch_add(&batch, token, Int32(i), [0], i == tokens.count - 1)
        }

        if llama_decode(ctx, batch) != 0 {
            throw LLMError.generationFailed("Decode prompt fallito")
        }

        // Generate tokens
        var generatedTokens = 0
        let vocabSize = llama_n_vocab(model)

        while generatedTokens < config.maxTokens && !shouldCancel {
            // Get logits
            let logits = llama_get_logits_ith(ctx, batch.n_tokens - 1)

            // Sampling
            var candidates: [llama_token_data] = []
            for i in 0..<Int(vocabSize) {
                candidates.append(llama_token_data(id: Int32(i), logit: logits![i], p: 0))
            }

            // Use withUnsafeMutableBufferPointer to get a stable pointer
            let newToken: llama_token = candidates.withUnsafeMutableBufferPointer { ptr in
                var candidatesP = llama_token_data_array(
                    data: ptr.baseAddress,
                    size: ptr.count,
                    sorted: false
                )

                // Apply temperature and top_p
                llama_sample_temp(ctx, &candidatesP, config.temperature)
                llama_sample_top_p(ctx, &candidatesP, config.topP, 1)
                llama_sample_top_k(ctx, &candidatesP, Int32(config.topK), 1)

                return llama_sample_token(ctx, &candidatesP)
            }

            // Check EOS
            if llama_token_is_eog(model, newToken) {
                break
            }

            // Decode and emit token
            let tokenText = decodeToken(token: newToken, model: model)
            onToken(tokenText)

            // Check stop sequences
            // TODO: Implement stop sequence checking

            // Prepare for next token
            llama_batch_clear(&batch)
            llama_batch_add(&batch, newToken, Int32(tokens.count + generatedTokens), [0], true)

            if llama_decode(ctx, batch) != 0 {
                throw LLMError.generationFailed("Decode token fallito")
            }

            generatedTokens += 1
        }

        // Reset context for next generation
        llama_kv_cache_clear(ctx)
    }

    private func tokenize(text: String, model: OpaquePointer) -> [llama_token] {
        let maxTokens = text.utf8.count + 16
        var tokens = [llama_token](repeating: 0, count: maxTokens)

        let n = llama_tokenize(model, text, Int32(text.utf8.count), &tokens, Int32(maxTokens), true, false)

        if n < 0 {
            return []
        }

        return Array(tokens.prefix(Int(n)))
    }

    private func decodeToken(token: llama_token, model: OpaquePointer) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let len = llama_token_to_piece(model, token, &buffer, 256, 0, false)

        if len < 0 {
            return ""
        }

        return String(cString: buffer)
    }
}

// MARK: - llama.cpp C Bindings Placeholder

// These are placeholders - will be provided by the llama.cpp package
// When adding llama.swift as a dependency, these get replaced

#if !canImport(llama)

// Placeholder types
typealias llama_token = Int32

struct llama_token_data {
    var id: Int32
    var logit: Float
    var p: Float
}

struct llama_token_data_array {
    var data: UnsafeMutablePointer<llama_token_data>?
    var size: Int
    var sorted: Bool
}

struct llama_batch {
    var n_tokens: Int32 = 0
}

// Placeholder functions - return safe values
func llama_backend_init() {}
func llama_model_default_params() -> llama_model_params { llama_model_params() }
func llama_context_default_params() -> llama_context_params { llama_context_params() }
func llama_load_model_from_file(_ path: String, _ params: llama_model_params) -> OpaquePointer? { nil }
func llama_new_context_with_model(_ model: OpaquePointer, _ params: llama_context_params) -> OpaquePointer? { nil }
func llama_free(_ ctx: OpaquePointer) {}
func llama_free_model(_ model: OpaquePointer) {}
func llama_n_vocab(_ model: OpaquePointer) -> Int32 { 0 }
func llama_tokenize(_ model: OpaquePointer, _ text: String, _ textLen: Int32, _ tokens: UnsafeMutablePointer<llama_token>, _ maxTokens: Int32, _ addBos: Bool, _ special: Bool) -> Int32 { 0 }
func llama_token_to_piece(_ model: OpaquePointer, _ token: llama_token, _ buf: UnsafeMutablePointer<CChar>, _ length: Int32, _ lstrip: Int32, _ special: Bool) -> Int32 { 0 }
func llama_token_is_eog(_ model: OpaquePointer, _ token: llama_token) -> Bool { false }
func llama_batch_init(_ nTokens: Int32, _ embd: Int32, _ nSeqMax: Int32) -> llama_batch { llama_batch() }
func llama_batch_free(_ batch: llama_batch) {}
func llama_batch_clear(_ batch: inout llama_batch) {}
func llama_batch_add(_ batch: inout llama_batch, _ token: llama_token, _ pos: Int32, _ seqIds: [Int32], _ logits: Bool) {}
func llama_decode(_ ctx: OpaquePointer, _ batch: llama_batch) -> Int32 { 0 }
func llama_get_logits_ith(_ ctx: OpaquePointer, _ i: Int32) -> UnsafeMutablePointer<Float>? { nil }
func llama_sample_temp(_ ctx: OpaquePointer, _ candidates: UnsafeMutablePointer<llama_token_data_array>, _ temp: Float) {}
func llama_sample_top_p(_ ctx: OpaquePointer, _ candidates: UnsafeMutablePointer<llama_token_data_array>, _ p: Float, _ minKeep: Int) {}
func llama_sample_top_k(_ ctx: OpaquePointer, _ candidates: UnsafeMutablePointer<llama_token_data_array>, _ k: Int32, _ minKeep: Int) {}
func llama_sample_token(_ ctx: OpaquePointer, _ candidates: UnsafeMutablePointer<llama_token_data_array>) -> llama_token { 0 }
func llama_kv_cache_clear(_ ctx: OpaquePointer) {}

struct llama_model_params {
    var use_mmap: Bool = true
    var use_mlock: Bool = false
    var n_gpu_layers: Int32 = 0
}

struct llama_context_params {
    var n_ctx: UInt32 = 2048
    var n_batch: UInt32 = 512
    var n_threads: UInt32 = 4
    var n_threads_batch: UInt32 = 4
}

#endif
