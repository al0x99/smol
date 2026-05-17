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
    /// Includes both GGUF and MLX format models
    static let modelCatalog: [LLMModel] = [
        // GGUF Models
        LLMModel(
            id: "qwen2-0.5b",
            name: "Qwen2 0.5B",
            description: "Ultra-light model. Basic responses, very fast.",
            size: .tiny,
            sizeBytes: 350_000_000,
            downloadURL: "https://huggingface.co/Qwen/Qwen2-0.5B-Instruct-GGUF/resolve/main/qwen2-0_5b-instruct-q4_k_m.gguf",
            requirements: ModelRequirements(minRAM: 1, recommendedRAM: 2, estimatedSpeed: 50),
            capabilities: [.chat, .systemAnalysis],
            format: .gguf
        ),
        LLMModel(
            id: "tinyllama-1.1b",
            name: "TinyLlama 1.1B",
            description: "Small but capable. Good quality/speed balance.",
            size: .small,
            sizeBytes: 670_000_000,
            downloadURL: "https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf",
            requirements: ModelRequirements(minRAM: 2, recommendedRAM: 4, estimatedSpeed: 35),
            capabilities: [.chat, .systemAnalysis, .codeAnalysis],
            format: .gguf
        ),
        LLMModel(
            id: "phi-2",
            name: "Phi-2 2.7B",
            description: "Microsoft Phi-2. Great for reasoning and analysis.",
            size: .medium,
            sizeBytes: 1_600_000_000,
            downloadURL: "https://huggingface.co/TheBloke/phi-2-GGUF/resolve/main/phi-2.Q4_K_M.gguf",
            requirements: ModelRequirements(minRAM: 4, recommendedRAM: 8, estimatedSpeed: 20),
            capabilities: [.chat, .systemAnalysis, .codeAnalysis, .reasoning],
            format: .gguf
        ),
        LLMModel(
            id: "gemma-2b",
            name: "Gemma 2B",
            description: "Google Gemma. Multilingual, good comprehension.",
            size: .medium,
            sizeBytes: 1_400_000_000,
            downloadURL: "https://huggingface.co/google/gemma-2b-it-GGUF/resolve/main/gemma-2b-it.Q4_K_M.gguf",
            requirements: ModelRequirements(minRAM: 4, recommendedRAM: 8, estimatedSpeed: 22),
            capabilities: [.chat, .systemAnalysis, .multilingual],
            format: .gguf
        ),
        LLMModel(
            id: "mistral-7b",
            name: "Mistral 7B",
            description: "Powerful model. Needs more resources but excellent quality.",
            size: .large,
            sizeBytes: 4_100_000_000,
            downloadURL: "https://huggingface.co/TheBloke/Mistral-7B-Instruct-v0.2-GGUF/resolve/main/mistral-7b-instruct-v0.2.Q4_K_M.gguf",
            requirements: ModelRequirements(minRAM: 8, recommendedRAM: 16, estimatedSpeed: 10),
            capabilities: [.chat, .systemAnalysis, .codeAnalysis, .reasoning, .multilingual],
            format: .gguf
        ),
        // MLX Models (Apple Silicon optimized)
        LLMModel(
            id: "qwen3-4b-mlx",
            name: "Qwen3 4B (MLX)",
            description: "Latest Qwen3, optimized for Apple Silicon. 4-bit quantized.",
            size: .medium,
            sizeBytes: 2_500_000_000,
            downloadURL: "https://huggingface.co/mlx-community/Qwen3-4B-4bit",
            requirements: ModelRequirements(minRAM: 4, recommendedRAM: 8, estimatedSpeed: 40),
            capabilities: [.chat, .systemAnalysis, .codeAnalysis, .reasoning, .multilingual],
            format: .mlx
        ),
        LLMModel(
            id: "phi-3.5-mini-mlx",
            name: "Phi 3.5 Mini (MLX)",
            description: "Microsoft Phi 3.5. Compact yet powerful, MLX optimized.",
            size: .medium,
            sizeBytes: 2_200_000_000,
            downloadURL: "https://huggingface.co/mlx-community/Phi-3.5-mini-instruct-4bit",
            requirements: ModelRequirements(minRAM: 4, recommendedRAM: 8, estimatedSpeed: 35),
            capabilities: [.chat, .systemAnalysis, .codeAnalysis, .reasoning],
            format: .mlx
        ),
        LLMModel(
            id: "gemma-2-2b-mlx",
            name: "Gemma 2 2B (MLX)",
            description: "Google Gemma 2. Fast and multilingual, MLX optimized.",
            size: .small,
            sizeBytes: 1_500_000_000,
            downloadURL: "https://huggingface.co/mlx-community/gemma-2-2b-it-4bit",
            requirements: ModelRequirements(minRAM: 2, recommendedRAM: 4, estimatedSpeed: 50),
            capabilities: [.chat, .systemAnalysis, .multilingual],
            format: .mlx
        ),
    ]

    // MARK: - Initialization

    private init() {
        modelsDirectory = URL.applicationSupportDirectory.appending(path: "smol/Models", directoryHint: .isDirectory)
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
        return modelPath(for: model) != nil
    }

    /// Path to the downloaded model
    func modelPath(for model: LLMModel) -> URL? {
        // Check format-specific path
        switch model.format {
        case .gguf:
            let path = modelsDirectory.appendingPathComponent("\(model.id).gguf")
            return FileManager.default.fileExists(atPath: path.path) ? path : nil
        case .mlx:
            // MLX models are directories
            let path = modelsDirectory.appendingPathComponent(model.id)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir), isDir.boolValue {
                return path
            }
            // Fallback to GGUF path
            let ggufPath = modelsDirectory.appendingPathComponent("\(model.id).gguf")
            return FileManager.default.fileExists(atPath: ggufPath.path) ? ggufPath : nil
        }
    }

    /// Check if the system has sufficient resources for a model
    func canRunModel(_ model: LLMModel) -> (canRun: Bool, warning: String?) {
        let totalRAM = Foundation.ProcessInfo.processInfo.physicalMemory
        let totalRAMGB = Double(totalRAM) / 1_073_741_824  // GB

        if totalRAMGB < Double(model.requirements.minRAM) {
            return (false, "Insufficient RAM. Requires at least \(model.requirements.minRAM) GB, available \(Int(totalRAMGB)) GB")
        }

        if totalRAMGB < Double(model.requirements.recommendedRAM) {
            return (true, "RAM below recommended (\(model.requirements.recommendedRAM) GB). May be slow.")
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

/// A downloadable on-device LLM (MLX or GGUF) and its metadata.
struct LLMModel: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    let size: ModelSize
    let sizeBytes: UInt64
    let downloadURL: String
    let requirements: ModelRequirements
    let capabilities: [ModelCapability]
    let format: ModelFormat

    var isDownloaded: Bool = false
    var actualSize: UInt64?

    init(id: String, name: String, description: String, size: ModelSize, sizeBytes: UInt64,
         downloadURL: String, requirements: ModelRequirements, capabilities: [ModelCapability],
         format: ModelFormat = .gguf) {
        self.id = id
        self.name = name
        self.description = description
        self.size = size
        self.sizeBytes = sizeBytes
        self.downloadURL = downloadURL
        self.requirements = requirements
        self.capabilities = capabilities
        self.format = format
    }

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

/// On-disk format of a downloaded model. GGUF runs via llama.cpp / MLX
/// conversion; MLX is the Apple Silicon-native `safetensors` layout.
enum ModelFormat: String, CaseIterable {
    case gguf = "GGUF"
    case mlx = "MLX"

    var description: String {
        switch self {
        case .gguf: return "GGUF — Quantized, single file"
        case .mlx: return "MLX — Apple Silicon optimized"
        }
    }

    var fileExtension: String {
        switch self {
        case .gguf: return "gguf"
        case .mlx: return "safetensors"
        }
    }

    var requiredBackend: LLMBackend {
        switch self {
        case .gguf: return .mlx  // GGUF also works via MLX with conversion
        case .mlx: return .mlx
        }
    }
}

/// Rough size bucket shown in the model picker.
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

/// Hardware requirements advertised for a model.
struct ModelRequirements {
    let minRAM: Int       // GB
    let recommendedRAM: Int  // GB
    let estimatedSpeed: Int  // tokens/sec on M1/M2
}

/// Tags advertised on a model card.
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

/// Errors surfaced by `ModelManager` during download / installation.
enum ModelError: LocalizedError {
    case alreadyDownloading
    case invalidURL
    case downloadFailed(String)
    case modelNotFound
    case insufficientResources

    var errorDescription: String? {
        switch self {
        case .alreadyDownloading:
            return "Download already in progress"
        case .invalidURL:
            return "Invalid model URL"
        case .downloadFailed(let reason):
            return "Download failed: \(reason)"
        case .modelNotFound:
            return "Model not found"
        case .insufficientResources:
            return "Insufficient resources to run the model"
        }
    }
}
