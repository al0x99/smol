import SwiftUI

// MARK: - Processes Tab

struct ProcessesTab: View {
    @ObservedObject var monitor: SystemMonitor
    @StateObject private var localization = LocalizationManager.shared
    @State private var sortOrder = [KeyPathComparator(\ProcessInfo.cpuPercent, order: .reverse)]
    @State private var searchText = ""
    @State private var allProcesses: [ProcessInfo] = []

    private var filteredProcesses: [ProcessInfo] {
        if searchText.isEmpty {
            return allProcesses
        }
        return allProcesses.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var anomalyCount: Int {
        allProcesses.filter { $0.isAnomaly }.count
    }

    private func refreshProcesses() {
        let analyzer = ProcessAnalyzer()
        allProcesses = analyzer.getTopProcessesByCPU(limit: 50)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header con statistiche
            HStack(spacing: 16) {
                // Ricerca
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("processes.search_placeholder".localized(localization), text: $searchText)
                        .textFieldStyle(.plain)

                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)

                Spacer()

                // Stats pills
                HStack(spacing: 8) {
                    StatPill(
                        icon: "list.number",
                        value: "\(filteredProcesses.count)",
                        label: "processes.count".localized(localization),
                        color: .blue
                    )

                    if anomalyCount > 0 {
                        StatPill(
                            icon: "exclamationmark.triangle.fill",
                            value: "\(anomalyCount)",
                            label: "processes.anomalies".localized(localization),
                            color: .orange
                        )
                    }
                }

                Button(action: refreshProcesses) {
                    Label("processes.refresh".localized(localization), systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding()
            .onAppear {
                refreshProcesses()
            }

            Divider()

            // Tabella processi
            Table(filteredProcesses, sortOrder: $sortOrder) {
                TableColumn("processes.name".localized(localization), value: \.name) { process in
                    HStack {
                        if process.isAnomaly {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.yellow)
                                .font(.caption)
                        }
                        Text(process.name)
                            .lineLimit(1)
                    }
                }
                .width(min: 150, ideal: 200)

                TableColumn("processes.cpu".localized(localization), value: \.cpuPercent) { process in
                    HStack {
                        Text(String(format: "%.1f%%", process.cpuPercent))
                            .foregroundColor(process.cpuPercent > 30 ? .red : .primary)
                        Spacer()
                        ProgressView(value: min(process.cpuPercent, 100) / 100)
                            .frame(width: 50)
                    }
                }
                .width(min: 100, ideal: 120)

                TableColumn("processes.memory".localized(localization), value: \.memoryBytes) { process in
                    Text(process.memoryFormatted)
                        .foregroundColor(.secondary)
                }
                .width(min: 80, ideal: 100)

                TableColumn("processes.cpu_time".localized(localization), value: \.cpuTimeMinutes) { process in
                    Text(formatCPUTime(process.cpuTimeMinutes))
                        .foregroundColor(.secondary)
                }
                .width(min: 80, ideal: 100)

                TableColumn("processes.pid".localized(localization), value: \.id) { process in
                    Text("\(process.id)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .width(min: 60, ideal: 70)
            }
        }
    }

    private func formatCPUTime(_ minutes: Double) -> String {
        if minutes < 1 {
            return String(format: "%.0fs", minutes * 60)
        } else if minutes < 60 {
            return String(format: "%.1fm", minutes)
        } else {
            let hours = minutes / 60
            return String(format: "%.1fh", hours)
        }
    }
}
