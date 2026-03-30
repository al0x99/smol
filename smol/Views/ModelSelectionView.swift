import SwiftUI

/// View for LLM model selection and download
struct ModelSelectionView: View {
    @StateObject private var modelManager = ModelManager.shared
    @StateObject private var inferenceManager = LLMInferenceManager.shared
    @State private var showDeleteConfirm = false
    @State private var modelToDelete: LLMModel?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            ModelSelectionHeader(
                downloadedCount: modelManager.downloadedModels.count,
                totalStorage: modelManager.totalStorageUsed
            )

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    // Backend Selection
                    BackendSelectionCard(
                        selectedBackend: $inferenceManager.selectedBackend,
                        isBackendAvailable: inferenceManager.isBackendAvailable
                    )

                    // Active model
                    if let active = modelManager.activeModel {
                        ActiveModelCard(model: active)
                    }

                    // Download in progress
                    if modelManager.isDownloading, let model = modelManager.downloadingModel {
                        DownloadProgressCard(
                            model: model,
                            progress: modelManager.downloadProgress,
                            onCancel: { modelManager.cancelDownload() }
                        )
                    }

                    // Download error
                    if let error = modelManager.downloadError {
                        ErrorBanner(message: error)
                    }

                    // Apple AI status card
                    AppleAIStatusCard()

                    // Available models list
                    Text("Available Models")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ForEach(modelManager.availableModels) { model in
                        ModelCard(
                            model: model,
                            isActive: modelManager.activeModel?.id == model.id,
                            canRun: modelManager.canRunModel(model),
                            onDownload: {
                                Task {
                                    try? await modelManager.downloadModel(model)
                                }
                            },
                            onActivate: {
                                modelManager.setActiveModel(model)
                            },
                            onDelete: {
                                modelToDelete = model
                                showDeleteConfirm = true
                            }
                        )
                    }

                    // Info footer
                    ModelInfoFooter()
                }
                .padding()
            }
        }
        .alert("Delete Model", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let model = modelToDelete {
                    try? modelManager.deleteModel(model)
                }
            }
        } message: {
            if let model = modelToDelete {
                Text("Delete \(model.name)? You'll need to download it again.")
            }
        }
    }
}

// MARK: - Header

struct ModelSelectionHeader: View {
    let downloadedCount: Int
    let totalStorage: UInt64

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Local AI Models")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("\(downloadedCount) downloaded • \(formattedStorage) used")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: "cpu")
                .font(.title)
                .foregroundStyle(
                    LinearGradient(
                        colors: [.purple, .blue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .padding()
    }

    private var formattedStorage: String {
        let gb = Double(totalStorage) / 1_073_741_824
        if gb >= 1 {
            return String(format: "%.1f GB", gb)
        } else {
            let mb = Double(totalStorage) / 1_048_576
            return String(format: "%.0f MB", mb)
        }
    }
}

// MARK: - Active Model Card

struct ActiveModelCard: View {
    let model: LLMModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundColor(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text("Active Model")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(model.name)
                    .font(.headline)
            }

            Spacer()

            Text("~\(model.requirements.estimatedSpeed) tok/s")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.2))
                .cornerRadius(8)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.green.opacity(0.1))
                .stroke(Color.green.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Download Progress Card

struct DownloadProgressCard: View {
    let model: LLMModel
    let progress: Double
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "arrow.down.circle")
                    .foregroundColor(.blue)

                Text("Downloading \(model.name)...")
                    .font(.subheadline)

                Spacer()

                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            ProgressView(value: progress)
                .progressViewStyle(.linear)

            HStack {
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Text(model.formattedSize)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.blue.opacity(0.1))
        )
    }
}

// MARK: - Model Card

struct ModelCard: View {
    let model: LLMModel
    let isActive: Bool
    let canRun: (canRun: Bool, warning: String?)
    let onDownload: () -> Void
    let onActivate: () -> Void
    let onDelete: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            // Main row
            HStack(spacing: 12) {
                // Size indicator
                ZStack {
                    Circle()
                        .fill(sizeColor.opacity(0.2))
                        .frame(width: 44, height: 44)

                    Image(systemName: model.sizeIcon)
                        .font(.title3)
                        .foregroundColor(sizeColor)
                }

                // Info
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(model.name)
                            .font(.headline)

                        if model.isDownloaded {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }

                    Text(model.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(isExpanded ? nil : 1)
                }

                Spacer()

                // Format + size badges
                VStack(spacing: 4) {
                    Text(model.format.rawValue)
                        .font(.caption2)
                        .fontWeight(.bold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(model.format == .mlx ? Color.purple.opacity(0.2) : Color.blue.opacity(0.2))
                        .cornerRadius(4)

                    Text(model.formattedSize)
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(sizeColor.opacity(0.2))
                        .cornerRadius(8)
                }

                // Expand button
                Button {
                    withAnimation(.spring(response: 0.3)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            // Expanded content
            if isExpanded {
                VStack(spacing: 12) {
                    Divider()

                    // Capabilities
                    HStack(spacing: 8) {
                        ForEach(model.capabilities, id: \.self) { cap in
                            HStack(spacing: 4) {
                                Image(systemName: cap.icon)
                                    .font(.caption2)
                                Text(cap.rawValue)
                                    .font(.caption2)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(6)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Requirements
                    HStack(spacing: 16) {
                        Label("Min: \(model.requirements.minRAM) GB RAM", systemImage: "memorychip")
                        Label("~\(model.requirements.estimatedSpeed) tok/s", systemImage: "speedometer")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Warning if any
                    if let warning = canRun.warning {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text(warning)
                                .font(.caption)
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(8)
                    }

                    // Actions
                    HStack(spacing: 12) {
                        if model.isDownloaded {
                            if isActive {
                                Text("Active")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.green)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.green.opacity(0.2))
                                    .cornerRadius(8)
                            } else {
                                Button("Use this") {
                                    onActivate()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }

                            Button(role: .destructive) {
                                onDelete()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        } else {
                            Button {
                                onDownload()
                            } label: {
                                Label("Download", systemImage: "arrow.down.circle")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(!canRun.canRun)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding([.horizontal, .bottom])
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
                .stroke(isActive ? Color.green.opacity(0.5) : Color.clear, lineWidth: 2)
        )
    }

    private var sizeColor: Color {
        switch model.size {
        case .tiny: return .green
        case .small: return .blue
        case .medium: return .orange
        case .large: return .red
        }
    }
}

// MARK: - Error Banner

struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)

            Text(message)
                .font(.caption)

            Spacer()
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.red.opacity(0.1))
        )
    }
}

// MARK: - Info Footer

struct ModelInfoFooter: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "info.circle")
                    .foregroundColor(.blue)
                Text("Model Information")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }

            Text("""
            • Models run **locally** on your Mac
            • No data is sent to external servers
            • Larger models = better responses but slower
            • GGUF format optimized for Apple Silicon
            """)
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.blue.opacity(0.05))
        )
    }
}

// MARK: - Apple AI Status Card

struct AppleAIStatusCard: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "apple.logo")
                .font(.title2)
                .foregroundColor(FoundationModelEngine.isAvailable ? .green : .secondary)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Apple AI (Foundation Models)")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    if FoundationModelEngine.isAvailable {
                        Text("Available")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2))
                            .cornerRadius(4)
                            .foregroundColor(.green)
                    }
                }

                Text(FoundationModelEngine.availabilityStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if FoundationModelEngine.isAvailable {
                    Text("Free on-device AI. No download needed — uses the system language model.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    Text("Requires macOS 26 (Tahoe) or later with Apple Silicon.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(FoundationModelEngine.isAvailable ? Color.green.opacity(0.05) : Color.secondary.opacity(0.05))
                .stroke(FoundationModelEngine.isAvailable ? Color.green.opacity(0.3) : Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }
}

// MARK: - Backend Selection Card

struct BackendSelectionCard: View {
    @Binding var selectedBackend: LLMBackend
    let isBackendAvailable: (LLMBackend) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "gearshape.2")
                    .foregroundColor(.purple)
                Text("Inference Backend")
                    .font(.headline)
                Spacer()
            }

            Text("Select the inference engine for AI models")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                ForEach(LLMBackend.allCases, id: \.self) { backend in
                    BackendOptionButton(
                        backend: backend,
                        isSelected: selectedBackend == backend,
                        isAvailable: isBackendAvailable(backend),
                        onSelect: { selectedBackend = backend }
                    )
                }
            }

            // Backend info
            HStack(spacing: 8) {
                Image(systemName: selectedBackend.icon)
                    .foregroundColor(.secondary)
                Text(selectedBackend.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)

            // Supported formats
            HStack(spacing: 4) {
                Text("Formats:")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                ForEach(selectedBackend.supportedFormats, id: \.self) { format in
                    Text(format.uppercased())
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.2))
                        .cornerRadius(4)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.purple.opacity(0.05))
                .stroke(Color.purple.opacity(0.2), lineWidth: 1)
        )
    }
}

struct BackendOptionButton: View {
    let backend: LLMBackend
    let isSelected: Bool
    let isAvailable: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                Image(systemName: backend.icon)
                    .font(.title2)
                    .foregroundColor(isSelected ? .white : (isAvailable ? .purple : .secondary))

                Text(backend.rawValue)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(isSelected ? .white : (isAvailable ? .primary : .secondary))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.purple : Color.secondary.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.clear : Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1.0 : 0.5)
    }
}

// MARK: - Preview

#Preview {
    ModelSelectionView()
        .frame(width: 600, height: 700)
}
