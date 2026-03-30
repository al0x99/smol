import Foundation
import Combine

// MARK: - Protocol

/// Protocollo comune per tutti i backend di inferenza LLM
protocol LLMInferenceEngine: AnyObject {
    /// Nome del backend
    var backendName: String { get }

    /// Se il modello è caricato e pronto
    var isModelLoaded: Bool { get }

    /// Modello attualmente caricato
    var loadedModelPath: URL? { get }

    /// Carica un modello dal path
    func loadModel(at path: URL, config: LLMConfig) async throws

    /// Scarica il modello dalla memoria
    func unloadModel()

    /// Genera testo dato un prompt
    func generate(prompt: String, config: GenerationConfig) async throws -> AsyncThrowingStream<String, Error>

    /// Genera risposta completa (non streaming)
    func generateComplete(prompt: String, config: GenerationConfig) async throws -> LLMResponse
}

// MARK: - Configuration Types

/// Configurazione per il caricamento del modello
struct LLMConfig: Sendable {
    var contextLength: Int = 2048
    var batchSize: Int = 512
    var threads: Int = 0  // 0 = auto
    var gpuLayers: Int = -1  // -1 = tutti su GPU se disponibile
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

/// Configurazione per la generazione
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

    /// Config per analisi sistema smol
    static let systemAnalysis = GenerationConfig(
        maxTokens: 256,
        temperature: 0.5,
        topP: 0.85,
        systemPrompt: """
        Sei un assistente AI integrato in smol, un'app di monitoraggio sistema per macOS.
        Rispondi in modo conciso e utile. Usa italiano se l'utente scrive in italiano.
        Puoi analizzare metriche di CPU, memoria, temperatura e processi.
        """
    )
}

/// Risposta dal modello
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

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Nessun modello caricato"
        case .modelLoadFailed(let reason):
            return "Caricamento modello fallito: \(reason)"
        case .generationFailed(let reason):
            return "Generazione fallita: \(reason)"
        case .backendNotAvailable(let backend):
            return "Backend \(backend) non disponibile"
        case .insufficientMemory:
            return "Memoria insufficiente per caricare il modello"
        case .invalidModelFormat:
            return "Formato modello non valido"
        case .cancelled:
            return "Operazione annullata"
        }
    }
}

// MARK: - Backend Type

enum LLMBackend: String, CaseIterable, Identifiable {
    case llamaCpp = "llama.cpp"
    case mlx = "MLX"
    case auto = "Auto"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .llamaCpp:
            return "llama.cpp - Supporta GGUF, compatibile con tutti i Mac"
        case .mlx:
            return "MLX - Ottimizzato Apple Silicon, massime performance"
        case .auto:
            return "Seleziona automaticamente il backend migliore"
        }
    }

    var icon: String {
        switch self {
        case .llamaCpp: return "terminal"
        case .mlx: return "apple.logo"
        case .auto: return "wand.and.stars"
        }
    }

    var supportedFormats: [String] {
        switch self {
        case .llamaCpp: return ["gguf", "ggml"]
        case .mlx: return ["safetensors", "mlx"]
        case .auto: return ["gguf", "ggml", "safetensors", "mlx"]
        }
    }
}

// MARK: - Inference Manager

/// Gestisce i backend di inferenza e fornisce un'interfaccia unificata
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

    private var llamaCppEngine: LlamaCppEngine?
    private var mlxEngine: MLXEngine?

    private var activeEngine: LLMInferenceEngine? {
        switch selectedBackend {
        case .llamaCpp:
            return llamaCppEngine
        case .mlx:
            return mlxEngine
        case .auto:
            // Preferisce MLX su Apple Silicon, altrimenti llama.cpp
            if isAppleSilicon && mlxEngine?.isModelLoaded == true {
                return mlxEngine
            }
            return llamaCppEngine
        }
    }

    // MARK: - Initialization

    private init() {
        llamaCppEngine = LlamaCppEngine()
        mlxEngine = MLXEngine()
    }

    // MARK: - Public API

    /// Carica un modello con il backend appropriato
    func loadModel(_ model: LLMModel, config: LLMConfig? = nil) async throws {
        let actualConfig = config ?? LLMConfig()

        guard let modelPath = ModelManager.shared.modelPath(for: model) else {
            throw LLMError.modelLoadFailed("Modello non scaricato")
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

    /// Scarica il modello corrente
    func unloadModel() {
        llamaCppEngine?.unloadModel()
        mlxEngine?.unloadModel()
        loadedModel = nil
    }

    /// Genera risposta (streaming)
    func generate(prompt: String, config: GenerationConfig? = nil) async throws -> AsyncThrowingStream<String, Error> {
        let actualConfig = config ?? GenerationConfig.systemAnalysis

        guard let engine = activeEngine, engine.isModelLoaded else {
            throw LLMError.modelNotLoaded
        }

        isGenerating = true
        generationProgress = ""

        return try await engine.generate(prompt: prompt, config: actualConfig)
    }

    /// Genera risposta completa
    func generateComplete(prompt: String, config: GenerationConfig? = nil) async throws -> LLMResponse {
        let actualConfig = config ?? GenerationConfig.systemAnalysis

        guard let engine = activeEngine, engine.isModelLoaded else {
            throw LLMError.modelNotLoaded
        }

        isGenerating = true
        generationProgress = "Generando..."

        let response = try await engine.generateComplete(prompt: prompt, config: actualConfig)

        isGenerating = false
        generationProgress = response.formattedStats

        return response
    }

    /// Verifica disponibilità backend
    func isBackendAvailable(_ backend: LLMBackend) -> Bool {
        switch backend {
        case .llamaCpp:
            return LlamaCppEngine.isAvailable
        case .mlx:
            return MLXEngine.isAvailable && isAppleSilicon
        case .auto:
            return true
        }
    }

    // MARK: - Private

    private func selectEngine(for modelPath: URL) -> LLMInferenceEngine {
        let ext = modelPath.pathExtension.lowercased()

        switch selectedBackend {
        case .llamaCpp:
            return llamaCppEngine!
        case .mlx:
            return mlxEngine!
        case .auto:
            // Auto-select basato su formato e hardware
            if ext == "gguf" || ext == "ggml" {
                return llamaCppEngine!
            } else if isAppleSilicon && (ext == "safetensors" || ext == "mlx") {
                return mlxEngine!
            }
            return llamaCppEngine!
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
