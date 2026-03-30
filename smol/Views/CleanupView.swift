import SwiftUI
import Combine
import os

/// System cleanup view - finds residuals and orphan LaunchAgents
struct CleanupView: View {
    @ObservedObject var monitor: SystemMonitor
    @StateObject private var cleanupService = CleanupService()
    @State private var isScanning = false
    @State private var selectedItems: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection

            Divider()

            // Main content
            if isScanning {
                scanningView
            } else if cleanupService.findings.isEmpty {
                emptyView
            } else {
                findingsListView
            }

            Divider()

            // Footer with actions
            footerSection
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("System Cleanup")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Find leftovers from removed apps and orphan LaunchAgents")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: startScan) {
                Label("Scan", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isScanning)
        }
        .padding()
    }

    // MARK: - Scanning View

    private var scanningView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Scanning...")
                .font(.headline)

            Text(cleanupService.currentScanStatus)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty View

    private var emptyView: some View {
        ContentUnavailableView(
            "No Leftovers Found",
            systemImage: "checkmark.circle",
            description: Text("System is clean! No orphan files or leftovers were found.")
        )
    }

    // MARK: - Findings List

    private var findingsListView: some View {
        List(selection: $selectedItems) {
            ForEach(CleanupCategory.allCases, id: \.self) { category in
                let items = cleanupService.findings.filter { $0.category == category }
                if !items.isEmpty {
                    Section(header: categoryHeader(category, count: items.count)) {
                        ForEach(items) { item in
                            FindingRow(item: item, isSelected: selectedItems.contains(item.id))
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func categoryHeader(_ category: CleanupCategory, count: Int) -> some View {
        HStack {
            Image(systemName: category.icon)
                .foregroundColor(category.color)
            Text(category.displayName)
            Spacer()
            Text("\(count) items")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            if !cleanupService.findings.isEmpty {
                Text("\(selectedItems.count) selected")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button("Select All") {
                    selectedItems = Set(cleanupService.findings.map { $0.id })
                }
                .buttonStyle(.borderless)

                Button("Deselect All") {
                    selectedItems.removeAll()
                }
                .buttonStyle(.borderless)
            }

            Spacer()

            if !selectedItems.isEmpty {
                let totalSize = cleanupService.findings
                    .filter { selectedItems.contains($0.id) }
                    .reduce(0) { $0 + $1.size }

                Text("Space: \(ByteCountFormatter.string(fromByteCount: Int64(totalSize), countStyle: .file))")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button("Delete Selected") {
                    deleteSelectedItems()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding()
    }

    // MARK: - Actions

    private func startScan() {
        isScanning = true
        selectedItems.removeAll()

        Task {
            await cleanupService.scan()
            await MainActor.run {
                isScanning = false
            }
        }
    }

    private func deleteSelectedItems() {
        let itemsToDelete = cleanupService.findings.filter { selectedItems.contains($0.id) }

        for item in itemsToDelete {
            do {
                try FileManager.default.removeItem(atPath: item.path)
                cleanupService.findings.removeAll { $0.id == item.id }
                selectedItems.remove(item.id)
            } catch {
                SmolLog.cleanup.error("Deletion error \(item.path, privacy: .public): \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Finding Row

struct FindingRow: View {
    let item: CleanupFinding
    let isSelected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .fontWeight(.medium)

                Text(item.path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let reason = item.reason {
                    Text(reason)
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }

            Spacer()

            VStack(alignment: .trailing) {
                Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                    .font(.caption)
                    .foregroundColor(.secondary)

                if item.isSafeToRemove {
                    Label("Safe", systemImage: "checkmark.shield")
                        .font(.caption2)
                        .foregroundColor(.green)
                } else {
                    Label("Caution", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundColor(.yellow)
                }
            }
        }
        .padding(.vertical, 4)
        .tag(item.id)
    }
}

// MARK: - Cleanup Service

@MainActor
class CleanupService: ObservableObject {
    @Published var findings: [CleanupFinding] = []
    @Published var currentScanStatus: String = ""

    func scan() async {
        findings.removeAll()

        // Scan LaunchAgents
        currentScanStatus = "Scanning LaunchAgents..."
        await scanLaunchAgents()

        // Scan Application Support
        currentScanStatus = "Scanning Application Support..."
        await scanApplicationSupport()

        // Scan Preferences
        currentScanStatus = "Scanning Preferences..."
        await scanPreferences()

        // Scan Caches
        currentScanStatus = "Scanning Caches..."
        await scanCaches()

        currentScanStatus = "Completed"
    }

    private func scanLaunchAgents() async {
        let paths = [
            NSHomeDirectory() + "/Library/LaunchAgents",
            "/Library/LaunchAgents"
        ]

        for basePath in paths {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: basePath) else { continue }

            for file in files where file.hasSuffix(".plist") {
                let fullPath = basePath + "/" + file
                if let plist = NSDictionary(contentsOfFile: fullPath),
                   let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first {

                    // Check if the executable exists
                    if !FileManager.default.fileExists(atPath: program) {
                        let size = (try? FileManager.default.attributesOfItem(atPath: fullPath)[.size] as? UInt64) ?? 0

                        let finding = CleanupFinding(
                            name: file,
                            path: fullPath,
                            category: .launchAgent,
                            size: size,
                            reason: "Executable not found: \(program)",
                            isSafeToRemove: true
                        )
                        findings.append(finding)
                    }
                }
            }
        }
    }

    private func scanApplicationSupport() async {
        let appSupportPath = NSHomeDirectory() + "/Library/Application Support"

        guard let folders = try? FileManager.default.contentsOfDirectory(atPath: appSupportPath) else { return }

        // Common system folders to ignore
        let systemFolders: Set<String> = [
            "com.apple", "Apple", "AddressBook", "Dock", "iCloud",
            "CloudDocs", "Knowledge", "CallHistoryDB", "Safari",
            "SyncServices", "com.apple.TCC", "FaceTime"
        ]

        for folder in folders {
            // Skip system folders
            if systemFolders.contains(where: { folder.contains($0) }) { continue }

            let folderPath = appSupportPath + "/" + folder

            // Check if a corresponding app exists
            let possibleAppPaths = [
                "/Applications/\(folder).app",
                "/Applications/\(folder.replacingOccurrences(of: " ", with: "")).app",
                NSHomeDirectory() + "/Applications/\(folder).app"
            ]

            let appExists = possibleAppPaths.contains { FileManager.default.fileExists(atPath: $0) }

            if !appExists {
                // Calculate folder size
                let size = folderSize(atPath: folderPath)

                // Only if > 1MB to avoid false positives
                if size > 1_000_000 {
                    let finding = CleanupFinding(
                        name: folder,
                        path: folderPath,
                        category: .applicationSupport,
                        size: size,
                        reason: "App not found in /Applications",
                        isSafeToRemove: false // More caution for Application Support
                    )
                    findings.append(finding)
                }
            }
        }
    }

    private func scanPreferences() async {
        let prefsPath = NSHomeDirectory() + "/Library/Preferences"

        guard let files = try? FileManager.default.contentsOfDirectory(atPath: prefsPath) else { return }

        // Pattern to identify third-party apps
        let thirdPartyPatterns = ["com.logitech", "com.adobe", "com.macpaw", "com.cleanmymac"]

        for file in files where file.hasSuffix(".plist") {
            for pattern in thirdPartyPatterns {
                if file.lowercased().contains(pattern) {
                    let fullPath = prefsPath + "/" + file
                    let size = (try? FileManager.default.attributesOfItem(atPath: fullPath)[.size] as? UInt64) ?? 0

                    let finding = CleanupFinding(
                        name: file,
                        path: fullPath,
                        category: .preferences,
                        size: size,
                        reason: "Preferences from removed app",
                        isSafeToRemove: true
                    )
                    findings.append(finding)
                }
            }
        }
    }

    private func scanCaches() async {
        let cachePath = NSHomeDirectory() + "/Library/Caches"

        guard let folders = try? FileManager.default.contentsOfDirectory(atPath: cachePath) else { return }

        for folder in folders {
            let folderPath = cachePath + "/" + folder
            let size = folderSize(atPath: folderPath)

            // Only cache > 100MB
            if size > 100_000_000 {
                let finding = CleanupFinding(
                    name: folder,
                    path: folderPath,
                    category: .cache,
                    size: size,
                    reason: "Large cache (>\(size / 1_000_000)MB)",
                    isSafeToRemove: true
                )
                findings.append(finding)
            }
        }
    }

    private func folderSize(atPath path: String) -> UInt64 {
        var totalSize: UInt64 = 0

        if let enumerator = FileManager.default.enumerator(atPath: path) {
            while let file = enumerator.nextObject() as? String {
                let filePath = path + "/" + file
                if let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
                   let size = attrs[.size] as? UInt64 {
                    totalSize += size
                }
            }
        }

        return totalSize
    }
}

// MARK: - Models

struct CleanupFinding: Identifiable {
    let id = UUID().uuidString
    let name: String
    let path: String
    let category: CleanupCategory
    let size: UInt64
    let reason: String?
    let isSafeToRemove: Bool
}

enum CleanupCategory: CaseIterable {
    case launchAgent
    case applicationSupport
    case preferences
    case cache

    var displayName: String {
        switch self {
        case .launchAgent: return "Orphan LaunchAgents"
        case .applicationSupport: return "Application Support"
        case .preferences: return "Preferences"
        case .cache: return "Cache"
        }
    }

    var icon: String {
        switch self {
        case .launchAgent: return "gearshape.2"
        case .applicationSupport: return "folder"
        case .preferences: return "slider.horizontal.3"
        case .cache: return "internaldrive"
        }
    }

    var color: Color {
        switch self {
        case .launchAgent: return .red
        case .applicationSupport: return .orange
        case .preferences: return .blue
        case .cache: return .purple
        }
    }
}

// MARK: - Preview

#Preview {
    CleanupView(monitor: SystemMonitor())
}
