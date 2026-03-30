import Foundation
import Combine

// MARK: - Protocol

/// Common protocol for all LLM inference backends
protocol LLMInferenceEngine: AnyObject {
    /// Backend name
    var backendName: String { get }

    /// Whether the model is loaded and ready
    var isModelLoaded: Bool { get }

    /// Currently loaded model
    var loadedModelPath: URL? { get }

    /// Load a model from path
    func loadModel(at path: URL, config: LLMConfig) async throws

    /// Unload the model from memory
    func unloadModel()

    /// Generate text given a prompt
    func generate(prompt: String, config: GenerationConfig) async throws -> AsyncThrowingStream<String, Error>

    /// Generate complete response (non streaming)
    func generateComplete(prompt: String, config: GenerationConfig) async throws -> LLMResponse
}

// MARK: - Configuration Types

/// Configuration for model loading
struct LLMConfig: Sendable {
    var contextLength: Int = 2048
    var batchSize: Int = 512
    var threads: Int = 0  // 0 = auto
    var gpuLayers: Int = -1  // -1 = all on GPU if available
    var useMmap: Bool = true
    var useMlock: Bool = false
    var verbose: Bool = false

    static let `default` = LLMConfig()

    static let lowMemory = LLMConfig(
        contextLength: 1024,
        batchSize: 256,
        gpuLayers: 0
    )

    static let highPerformance = LLMConfig(
        contextLength: 4096,
        batchSize: 1024,
        gpuLayers: -1
    )
}

/// Configuration for generation
struct GenerationConfig: Sendable {
    var maxTokens: Int = 512
    var temperature: Float = 0.7
    var topP: Float = 0.9
    var topK: Int = 40
    var repeatPenalty: Float = 1.1
    var stopSequences: [String] = []
    var systemPrompt: String?

    static let `default` = GenerationConfig()

    static let creative = GenerationConfig(
        temperature: 0.9,
        topP: 0.95,
        topK: 50
    )

    static let precise = GenerationConfig(
        temperature: 0.3,
        topP: 0.8,
        topK: 20
    )

    /// Config for smol system analysis
    static let systemAnalysis = GenerationConfig(
        maxTokens: 256,
        temperature: 0.5,
        topP: 0.85,
        systemPrompt: """
        You are smol, an AI assistant built into a macOS system monitoring app.
        Respond concisely and helpfully. Match the user's language.
        You can analyze CPU, memory, temperature, and process metrics.
        """
    )
}

/// Response from the model
struct LLMResponse {
    let text: String
    let tokenCount: Int
    let generationTime: TimeInterval
    let tokensPerSecond: Double
    let finishReason: FinishReason

    enum FinishReason: String {
        case complete = "complete"
        case maxTokens = "max_tokens"
        case stopSequence = "stop_sequence"
        case error = "error"
    }

    var formattedStats: String {
        String(format: "%d tokens in %.1fs (%.1f tok/s)",
               tokenCount, generationTime, tokensPerSecond)
    }
}

// MARK: - Errors

enum LLMError: LocalizedError {
    case modelNotLoaded
    case modelLoadFailed(String)
    case generationFailed(String)
    case backendNotAvailable(String)
    case insufficientMemory
    case invalidModelFormat
    case cancelled
    case networkUnavailable
    case apiKeyMissing

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "No model loaded"
        case .modelLoadFailed(let reason):
            return "Model load failed: \(reason)"
        case .generationFailed(let reason):
            return "Generation failed: \(reason)"
        case .backendNotAvailable(let backend):
            return "Backend \(backend) not available"
        case .insufficientMemory:
            return "Insufficient memory to load model"
        case .invalidModelFormat:
            return "Invalid model format"
        case .cancelled:
            return "Operation cancelled"
        case .networkUnavailable:
            return "No network connection"
        case .apiKeyMissing:
            return "API key not configured"
        }
    }
}

// MARK: - Backend Type

enum LLMBackend: String, CaseIterable, Identifiable {
    case openRouter = "Cloud"
    case mlx = "MLX"
    case auto = "Auto"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .openRouter:
            return "Cloud — OpenRouter, Together AI, Groq, OpenAI"
        case .mlx:
            return "MLX — On-device Apple Silicon inference"
        case .auto:
            return "Auto-select the best available backend"
        }
    }

    var icon: String {
        switch self {
        case .openRouter: return "cloud"
        case .mlx: return "apple.logo"
        case .auto: return "wand.and.stars"
        }
    }

    var supportedFormats: [String] {
        switch self {
        case .openRouter: return []
        case .mlx: return ["safetensors", "mlx"]
        case .auto: return ["safetensors", "mlx"]
        }
    }
}

// MARK: - Inference Manager

/// Manages inference backends and provides a unified interface
@MainActor
class LLMInferenceManager: ObservableObject {
    static let shared = LLMInferenceManager()

    // MARK: - Published State

    @Published var selectedBackend: LLMBackend = .auto
    @Published var isLoading = false
    @Published var isGenerating = false
    @Published var loadedModel: LLMModel?
    @Published var lastError: String?
    @Published var generationProgress: String = ""

    // MARK: - Engines

    private var openRouterEngine: OpenRouterEngine?
    private var mlxEngine: MLXEngine?

    var activeEngine: LLMInferenceEngine? {
        resolveActiveEngine()
    }

    private func resolveActiveEngine() -> LLMInferenceEngine? {
        switch selectedBackend {
        case .openRouter:
            return openRouterEngine
        case .mlx:
            return mlxEngine
        case .auto:
            // Priority: MLX (if loaded) → OpenRouter (if key set) → nil
            if isAppleSilicon && mlxEngine?.isModelLoaded == true {
                return mlxEngine
            }
            if openRouterEngine?.isModelLoaded == true {
                return openRouterEngine
            }
            return nil
        }
    }

    // MARK: - Initialization

    private init() {
        openRouterEngine = OpenRouterEngine()
        mlxEngine = MLXEngine()
    }

    // MARK: - Public API

    /// Load a model with the appropriate backend
    func loadModel(_ model: LLMModel, config: LLMConfig? = nil) async throws {
        let actualConfig = config ?? LLMConfig()

        guard let modelPath = ModelManager.shared.modelPath(for: model) else {
            throw LLMError.modelLoadFailed("Model not downloaded")
        }

        isLoading = true
        lastError = nil

        do {
            let engine = selectEngine(for: modelPath)
            try await engine.loadModel(at: modelPath, config: actualConfig)
            loadedModel = model
            isLoading = false
        } catch {
            isLoading = false
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Initialize the cloud backend (no model download needed)
    func initializeCloudBackend() async throws {
        guard let engine = openRouterEngine else {
            throw LLMError.backendNotAvailable("Cloud engine not initialized")
        }
        engine.reloadConfig()
        guard engine.isModelLoaded else {
            throw LLMError.apiKeyMissing
        }
    }

    /// Unload the current model
    func unloadModel() {
        openRouterEngine?.unloadModel()
        mlxEngine?.unloadModel()
        loadedModel = nil
    }

    /// Generate response (streaming)
    func generate(prompt: String, config: GenerationConfig? = nil) async throws -> AsyncThrowingStream<String, Error> {
        let actualConfig = config ?? GenerationConfig.systemAnalysis

        guard let engine = activeEngine, engine.isModelLoaded else {
            throw LLMError.modelNotLoaded
        }

        isGenerating = true
        generationProgress = ""

        return try await engine.generate(prompt: prompt, config: actualConfig)
    }

    /// Generate complete response
    func generateComplete(prompt: String, config: GenerationConfig? = nil) async throws -> LLMResponse {
        let actualConfig = config ?? GenerationConfig.systemAnalysis

        guard let engine = activeEngine, engine.isModelLoaded else {
            throw LLMError.modelNotLoaded
        }

        isGenerating = true
        generationProgress = "Generating..."

        let response = try await engine.generateComplete(prompt: prompt, config: actualConfig)

        isGenerating = false
        generationProgress = response.formattedStats

        return response
    }

    /// Check backend availability
    func isBackendAvailable(_ backend: LLMBackend) -> Bool {
        switch backend {
        case .openRouter:
            return OpenRouterEngine.isAvailable
        case .mlx:
            return MLXEngine.isAvailable && isAppleSilicon
        case .auto:
            return true
        }
    }

    /// Try to generate with automatic fallback across backends
    func generateWithFallback(prompt: String, config: GenerationConfig? = nil) async throws -> (response: LLMResponse, backend: String) {
        let actualConfig = config ?? GenerationConfig.systemAnalysis

        // Try active engine first
        if let engine = resolveActiveEngine(), engine.isModelLoaded {
            let response = try await engine.generateComplete(prompt: prompt, config: actualConfig)
            isGenerating = false
            return (response, engine.backendName)
        }

        // Try OpenRouter if key is set
        if let engine = openRouterEngine {
            engine.reloadConfig()
            if engine.isModelLoaded {
                let response = try await engine.generateComplete(prompt: prompt, config: actualConfig)
                isGenerating = false
                return (response, engine.backendName)
            }
        }

        throw LLMError.modelNotLoaded
    }

    // MARK: - Private

    private func selectEngine(for modelPath: URL) -> LLMInferenceEngine {
        let ext = modelPath.pathExtension.lowercased()

        switch selectedBackend {
        case .openRouter:
            return openRouterEngine!
        case .mlx:
            return mlxEngine!
        case .auto:
            if isAppleSilicon && (ext == "safetensors" || ext == "mlx") {
                return mlxEngine!
            }
            return openRouterEngine!
        }
    }

    private var isAppleSilicon: Bool {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
        return machine.hasPrefix("arm64")
    }
}
