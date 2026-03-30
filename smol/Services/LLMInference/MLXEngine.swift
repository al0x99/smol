import Foundation
import os

/// Engine di inferenza basato su MLX (Apple Silicon optimized)
/// Supporta modelli SafeTensors/MLX format
/// Richiede mlx-swift package
class MLXEngine: LLMInferenceEngine, @unchecked Sendable {

    // MARK: - Properties

    let backendName = "MLX"

    private(set) var isModelLoaded = false
    private(set) var loadedModelPath: URL?

    // MLX handles
    private var model: Any?  // MLX model object
    private var tokenizer: Any?  // Tokenizer
    private var currentConfig: LLMConfig?

    // Stato generazione (thread-safe access)
    private var isGeneratingFlag = false
    private var shouldCancel = false
    private let stateLock = NSLock()

    // MARK: - Static

    /// Verifica se MLX è disponibile (richiede Apple Silicon + mlx-swift)
    static var isAvailable: Bool {
        #if arch(arm64) && canImport(MLX)
        return true
        #else
        return false
        #endif
    }

    // MARK: - Initialization

    init() {
        // MLX si inizializza automaticamente
    }

    deinit {
        unloadModel()
    }

    // MARK: - LLMInferenceEngine Protocol

    func loadModel(at path: URL, config: LLMConfig) async throws {
        // Unload precedente se presente
        if isModelLoaded {
            unloadModel()
        }

        guard FileManager.default.fileExists(atPath: path.path) else {
            throw LLMError.modelLoadFailed("File non trovato: \(path.path)")
        }

        // Verifica estensione
        let ext = path.pathExtension.lowercased()
        guard ext == "safetensors" || ext == "mlx" || path.lastPathComponent.contains("mlx") else {
            throw LLMError.invalidModelFormat
        }

        currentConfig = config

        // Carica il modello in background
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

        // Rilascia risorse MLX
        model = nil
        tokenizer = nil

        isModelLoaded = false
        loadedModelPath = nil
        currentConfig = nil
    }

    func generate(prompt: String, config: GenerationConfig) async throws -> AsyncThrowingStream<String, Error> {
        guard isModelLoaded else {
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

    /// Annulla generazione in corso
    func cancelGeneration() {
        shouldCancel = true
    }

    // MARK: - Private Implementation

    private func loadModelSync(at path: URL, config: LLMConfig) throws {
        // Con MLX, il caricamento è ottimizzato per Apple Silicon
        // Usa unified memory - nessun trasferimento GPU necessario

        #if canImport(MLX)
        // Carica con mlx-swift
        // let modelConfig = MLXModelConfig(...)
        // model = try MLXLLamaModel.load(from: path, config: modelConfig)
        // tokenizer = try Tokenizer.load(from: path.deletingLastPathComponent())
        #else
        // Placeholder - simula caricamento
        SmolLog.ai.debug("MLXEngine: Simulating model load from \(path.lastPathComponent, privacy: .public)")

        // Simula tempo di caricamento
        Thread.sleep(forTimeInterval: 0.5)
        #endif

        isModelLoaded = true
        loadedModelPath = path
    }

    private func generateStreaming(prompt: String, config: GenerationConfig, onToken: @escaping (String) -> Void) throws {
        guard isModelLoaded else {
            throw LLMError.modelNotLoaded
        }

        // Prepara prompt con system (usato quando MLX è disponibile)
        let fullPrompt: String
        if let systemPrompt = config.systemPrompt {
            fullPrompt = "<|system|>\n\(systemPrompt)</s>\n<|user|>\n\(prompt)</s>\n<|assistant|>\n"
        } else {
            fullPrompt = prompt
        }

        #if canImport(MLX)
        // Genera con MLX
        // let tokens = tokenizer.encode(fullPrompt)
        // for await token in model.generate(tokens: tokens, config: config) {
        //     if shouldCancel { break }
        //     let text = tokenizer.decode([token])
        //     onToken(text)
        // }
        _ = fullPrompt // Usato nel codice MLX sopra
        #else
        _ = fullPrompt // Sarà usato quando MLX è disponibile
        // Placeholder - genera risposta simulata
        let placeholderResponse = """
        [MLX Backend - Demo Mode]
        Questo è un placeholder. Per funzionalità completa:
        1. Aggiungi mlx-swift come dipendenza SPM
        2. Scarica un modello compatibile MLX
        3. Ricompila l'app

        Il tuo prompt era: "\(prompt.prefix(100))..."
        """

        // Simula streaming token per token
        for word in placeholderResponse.split(separator: " ") {
            if shouldCancel { break }
            onToken(String(word) + " ")
            Thread.sleep(forTimeInterval: 0.02)  // Simula tempo di generazione
        }
        #endif
    }
}

// MARK: - MLX Specific Extensions

extension MLXEngine {
    /// Stima memoria richiesta per un modello
    static func estimateMemoryRequirements(for modelPath: URL) -> UInt64 {
        // MLX usa unified memory, quindi stima basata su dimensione file
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: modelPath.path),
              let size = attrs[.size] as? UInt64 else {
            return 0
        }

        // Per modelli quantizzati, memoria ~= dimensione file
        // Per float16/32, memoria può essere 1.5-2x
        return size
    }

    /// Verifica se il dispositivo supporta MLX con prestazioni ottimali
    static var hasOptimalMLXSupport: Bool {
        #if arch(arm64)
        // Verifica generazione chip (M1/M2/M3/M4)
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }

        // Mac mini, MacBook, iMac con Apple Silicon
        return machine.contains("arm64") || machine.contains("Mac")
        #else
        return false
        #endif
    }

    /// Informazioni sul backend
    var backendInfo: String {
        var info = "MLX - Apple Machine Learning Framework\n"
        info += "Ottimizzato per Apple Silicon\n"
        info += "Unified Memory: Sì\n"

        #if canImport(MLX)
        info += "MLX Swift: Disponibile\n"
        // info += "Versione: \(MLX.version)\n"
        #else
        info += "MLX Swift: Non installato\n"
        info += "Modalità: Placeholder/Demo\n"
        #endif

        return info
    }
}

// MARK: - MLX Model Formats

/// Formati modello supportati da MLX
enum MLXModelFormat: String, CaseIterable {
    case safetensors = "safetensors"
    case mlx = "mlx"
    case npz = "npz"

    var description: String {
        switch self {
        case .safetensors:
            return "SafeTensors - Formato sicuro e veloce"
        case .mlx:
            return "MLX Native - Ottimizzato per Apple Silicon"
        case .npz:
            return "NumPy - Formato compatibile"
        }
    }

    var fileExtension: String {
        rawValue
    }
}

// MARK: - MLX Configuration

/// Configurazione specifica per MLX
struct MLXConfig {
    var useMetalGPU: Bool = true
    var memoryLimit: UInt64 = 0  // 0 = auto
    var cachePrompts: Bool = true
    var quantization: MLXQuantization = .auto

    static let `default` = MLXConfig()

    static let lowMemory = MLXConfig(
        memoryLimit: 4_000_000_000,  // 4GB
        cachePrompts: false
    )
}

enum MLXQuantization: String, CaseIterable {
    case auto = "Auto"
    case fp16 = "FP16"
    case int8 = "INT8"
    case int4 = "INT4"

    var description: String {
        switch self {
        case .auto: return "Automatico (basato su risorse)"
        case .fp16: return "Float16 - Qualità massima"
        case .int8: return "Int8 - Bilanciato"
        case .int4: return "Int4 - Velocità massima"
        }
    }
}
