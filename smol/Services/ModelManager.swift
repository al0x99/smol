import Foundation
import Combine

/// Manages download and storage of local LLM models
@MainActor
class ModelManager: ObservableObject {
    static let shared = ModelManager()

    // MARK: - Published State

    @Published var availableModels: [LLMModel] = []
    @Published var downloadedModels: [LLMModel] = []
    @Published var activeModel: LLMModel?
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var downloadingModel: LLMModel?
    @Published var totalStorageUsed: UInt64 = 0
    @Published var downloadError: String?

    // MARK: - Storage

    private let modelsDirectory: URL
    private var downloadTask: URLSessionDownloadTask?

    // MARK: - Model Catalog

    /// Available models for download
    /// Uses GGUF models compatible with llama.cpp / MLX
    static let modelCatalog: [LLMModel] = [
        LLMModel(
            id: "qwen2-0.5b",
            name: "Qwen2 0.5B",
            description: "Modello ultra-leggero. Risposte base, velocissimo.",
            size: .tiny,
            sizeBytes: 350_000_000,  // ~350 MB
            downloadURL: "https://huggingface.co/Qwen/Qwen2-0.5B-Instruct-GGUF/resolve/main/qwen2-0_5b-instruct-q4_k_m.gguf",
            requirements: ModelRequirements(minRAM: 1, recommendedRAM: 2, estimatedSpeed: 50),
            capabilities: [.chat, .systemAnalysis]
        ),
        LLMModel(
            id: "tinyllama-1.1b",
            name: "TinyLlama 1.1B",
            description: "Piccolo ma capace. Buon bilanciamento qualità/velocità.",
            size: .small,
            sizeBytes: 670_000_000,  // ~670 MB
            downloadURL: "https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf",
            requirements: ModelRequirements(minRAM: 2, recommendedRAM: 4, estimatedSpeed: 35),
            capabilities: [.chat, .systemAnalysis, .codeAnalysis]
        ),
        LLMModel(
            id: "phi-2",
            name: "Phi-2 2.7B",
            description: "Microsoft Phi-2. Ottimo per ragionamento e analisi.",
            size: .medium,
            sizeBytes: 1_600_000_000,  // ~1.6 GB
            downloadURL: "https://huggingface.co/TheBloke/phi-2-GGUF/resolve/main/phi-2.Q4_K_M.gguf",
            requirements: ModelRequirements(minRAM: 4, recommendedRAM: 8, estimatedSpeed: 20),
            capabilities: [.chat, .systemAnalysis, .codeAnalysis, .reasoning]
        ),
        LLMModel(
            id: "gemma-2b",
            name: "Gemma 2B",
            description: "Google Gemma. Multilingue, buona comprensione.",
            size: .medium,
            sizeBytes: 1_400_000_000,  // ~1.4 GB
            downloadURL: "https://huggingface.co/google/gemma-2b-it-GGUF/resolve/main/gemma-2b-it.Q4_K_M.gguf",
            requirements: ModelRequirements(minRAM: 4, recommendedRAM: 8, estimatedSpeed: 22),
            capabilities: [.chat, .systemAnalysis, .multilingual]
        ),
        LLMModel(
            id: "mistral-7b",
            name: "Mistral 7B",
            description: "Modello potente. Richiede più risorse ma ottima qualità.",
            size: .large,
            sizeBytes: 4_100_000_000,  // ~4.1 GB
            downloadURL: "https://huggingface.co/TheBloke/Mistral-7B-Instruct-v0.2-GGUF/resolve/main/mistral-7b-instruct-v0.2.Q4_K_M.gguf",
            requirements: ModelRequirements(minRAM: 8, recommendedRAM: 16, estimatedSpeed: 10),
            capabilities: [.chat, .systemAnalysis, .codeAnalysis, .reasoning, .multilingual]
        )
    ]

    // MARK: - Initialization

    private init() {
        // Setup models directory
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        modelsDirectory = appSupport.appendingPathComponent("smol/Models", isDirectory: true)

        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        // Load catalog and check downloaded
        availableModels = Self.modelCatalog
        refreshDownloadedModels()
        loadActiveModel()
    }

    // MARK: - Public API

    /// Download a model
    func downloadModel(_ model: LLMModel) async throws {
        guard !isDownloading else {
            throw ModelError.alreadyDownloading
        }

        guard let url = URL(string: model.downloadURL) else {
            throw ModelError.invalidURL
        }

        isDownloading = true
        downloadingModel = model
        downloadProgress = 0
        downloadError = nil

        let destinationURL = modelsDirectory.appendingPathComponent("\(model.id).gguf")

        do {
            // Use URLSession for download with progress
            let (tempURL, _) = try await downloadWithProgress(from: url)

            // Move to final destination
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)

            // Update state
            refreshDownloadedModels()

            // If it's the first model, set it as active
            if activeModel == nil {
                setActiveModel(model)
            }

            isDownloading = false
            downloadingModel = nil
            downloadProgress = 1.0

        } catch {
            isDownloading = false
            downloadingModel = nil
            downloadError = error.localizedDescription
            throw error
        }
    }

    /// Cancel download in progress
    func cancelDownload() {
        downloadTask?.cancel()
        isDownloading = false
        downloadingModel = nil
        downloadProgress = 0
    }

    /// Delete a downloaded model
    func deleteModel(_ model: LLMModel) throws {
        let modelPath = modelsDirectory.appendingPathComponent("\(model.id).gguf")

        if FileManager.default.fileExists(atPath: modelPath.path) {
            try FileManager.default.removeItem(at: modelPath)
        }

        if activeModel?.id == model.id {
            activeModel = nil
            saveActiveModel()
        }

        refreshDownloadedModels()
    }

    /// Set the active model
    func setActiveModel(_ model: LLMModel) {
        activeModel = model
        saveActiveModel()
    }

    /// Check if a model is downloaded
    func isModelDownloaded(_ model: LLMModel) -> Bool {
        let modelPath = modelsDirectory.appendingPathComponent("\(model.id).gguf")
        return FileManager.default.fileExists(atPath: modelPath.path)
    }

    /// Path to the downloaded model
    func modelPath(for model: LLMModel) -> URL? {
        let path = modelsDirectory.appendingPathComponent("\(model.id).gguf")
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    /// Check if the system has sufficient resources for a model
    func canRunModel(_ model: LLMModel) -> (canRun: Bool, warning: String?) {
        let totalRAM = Foundation.ProcessInfo.processInfo.physicalMemory
        let totalRAMGB = Double(totalRAM) / 1_073_741_824  // GB

        if totalRAMGB < Double(model.requirements.minRAM) {
            return (false, "RAM insufficiente. Richiesti almeno \(model.requirements.minRAM) GB, disponibili \(Int(totalRAMGB)) GB")
        }

        if totalRAMGB < Double(model.requirements.recommendedRAM) {
            return (true, "RAM sotto il raccomandato (\(model.requirements.recommendedRAM) GB). Potrebbe essere lento.")
        }

        return (true, nil)
    }

    // MARK: - Private Methods

    private func downloadWithProgress(from url: URL) async throws -> (URL, URLResponse) {
        return try await withCheckedThrowingContinuation { continuation in
            let session = URLSession(configuration: .default, delegate: DownloadDelegate(progressHandler: { [weak self] progress in
                Task { @MainActor in
                    self?.downloadProgress = progress
                }
            }, completionHandler: { result in
                continuation.resume(with: result)
            }), delegateQueue: nil)

            let task = session.downloadTask(with: url)
            self.downloadTask = task
            task.resume()
        }
    }

    private func refreshDownloadedModels() {
        var downloaded: [LLMModel] = []
        var totalSize: UInt64 = 0

        for model in availableModels {
            let path = modelsDirectory.appendingPathComponent("\(model.id).gguf")
            if FileManager.default.fileExists(atPath: path.path) {
                var downloadedModel = model
                downloadedModel.isDownloaded = true

                if let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
                   let size = attrs[.size] as? UInt64 {
                    downloadedModel.actualSize = size
                    totalSize += size
                }

                downloaded.append(downloadedModel)
            }
        }

        downloadedModels = downloaded
        totalStorageUsed = totalSize

        // Update flag in availableModels
        for i in 0..<availableModels.count {
            availableModels[i].isDownloaded = downloaded.contains { $0.id == availableModels[i].id }
        }
    }

    private func saveActiveModel() {
        UserDefaults.standard.set(activeModel?.id, forKey: "activeModelId")
    }

    private func loadActiveModel() {
        if let id = UserDefaults.standard.string(forKey: "activeModelId"),
           let model = downloadedModels.first(where: { $0.id == id }) {
            activeModel = model
        }
    }
}

// MARK: - Download Delegate

private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let progressHandler: (Double) -> Void
    let completionHandler: (Result<(URL, URLResponse), Error>) -> Void

    init(progressHandler: @escaping (Double) -> Void,
         completionHandler: @escaping (Result<(URL, URLResponse), Error>) -> Void) {
        self.progressHandler = progressHandler
        self.completionHandler = completionHandler
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response else {
            completionHandler(.failure(ModelError.downloadFailed("No response")))
            return
        }

        // Copy to temp because location gets deleted
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gguf")
        do {
            try FileManager.default.copyItem(at: location, to: tempURL)
            completionHandler(.success((tempURL, response)))
        } catch {
            completionHandler(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        progressHandler(progress)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            completionHandler(.failure(error))
        }
    }
}

// MARK: - Model Types

struct LLMModel: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    let size: ModelSize
    let sizeBytes: UInt64
    let downloadURL: String
    let requirements: ModelRequirements
    let capabilities: [ModelCapability]

    var isDownloaded: Bool = false
    var actualSize: UInt64?

    var formattedSize: String {
        let sizeGB = Double(sizeBytes) / 1_073_741_824
        if sizeGB >= 1 {
            return String(format: "%.1f GB", sizeGB)
        } else {
            let sizeMB = Double(sizeBytes) / 1_048_576
            return String(format: "%.0f MB", sizeMB)
        }
    }

    var sizeIcon: String {
        switch size {
        case .tiny: return "leaf"
        case .small: return "hare"
        case .medium: return "tortoise"
        case .large: return "externaldrive.fill"
        }
    }

    var sizeColor: String {
        switch size {
        case .tiny: return "green"
        case .small: return "blue"
        case .medium: return "orange"
        case .large: return "red"
        }
    }

    static func == (lhs: LLMModel, rhs: LLMModel) -> Bool {
        lhs.id == rhs.id
    }
}

enum ModelSize: String, CaseIterable {
    case tiny = "Tiny"
    case small = "Small"
    case medium = "Medium"
    case large = "Large"

    var description: String {
        switch self {
        case .tiny: return "< 500 MB"
        case .small: return "500 MB - 1 GB"
        case .medium: return "1 - 3 GB"
        case .large: return "> 3 GB"
        }
    }
}

struct ModelRequirements {
    let minRAM: Int       // GB
    let recommendedRAM: Int  // GB
    let estimatedSpeed: Int  // tokens/sec su M1/M2
}

enum ModelCapability: String, CaseIterable {
    case chat = "Chat"
    case systemAnalysis = "System Analysis"
    case codeAnalysis = "Code Analysis"
    case reasoning = "Reasoning"
    case multilingual = "Multilingual"

    var icon: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .systemAnalysis: return "gauge"
        case .codeAnalysis: return "chevron.left.forwardslash.chevron.right"
        case .reasoning: return "brain"
        case .multilingual: return "globe"
        }
    }
}

enum ModelError: LocalizedError {
    case alreadyDownloading
    case invalidURL
    case downloadFailed(String)
    case modelNotFound
    case insufficientResources

    var errorDescription: String? {
        switch self {
        case .alreadyDownloading:
            return "Download già in corso"
        case .invalidURL:
            return "URL del modello non valido"
        case .downloadFailed(let reason):
            return "Download fallito: \(reason)"
        case .modelNotFound:
            return "Modello non trovato"
        case .insufficientResources:
            return "Risorse insufficienti per eseguire il modello"
        }
    }
}
