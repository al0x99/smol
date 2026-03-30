import SwiftUI

// MARK: - Reusable Components

struct HealthHeaderView: View {
    let health: SystemHealth
    @StateObject private var localization = LocalizationManager.shared

    var body: some View {
        HStack {
            Image(systemName: health.iconName)
                .font(.system(size: 40))
                .foregroundColor(health.color)

            VStack(alignment: .leading) {
                Text(statusText)
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(health.description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding()
        .background(health.color.opacity(0.1))
        .cornerRadius(12)
    }

    private var statusText: String {
        switch health {
        case .healthy: return "overview.system_healthy".localized(localization)
        case .warning: return "overview.warning".localized(localization)
        case .critical: return "overview.critical".localized(localization)
        }
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundColor(color)

            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(12)
    }
}

struct RAMDetailView: View {
    let memoryInfo: MemoryInfo

    var body: some View {
        GroupBox("Memory Details") {
            VStack(spacing: 12) {
                HStack {
                    Text("Used")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(memoryInfo.used), countStyle: .memory))
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Total")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(memoryInfo.total), countStyle: .memory))
                        .foregroundColor(.secondary)
                }

                Divider()

                HStack {
                    Text("Memory Pressure")
                        .fontWeight(.medium)
                    Spacer()
                    Text(String(format: "%.0f%%", memoryInfo.pressure))
                        .foregroundColor(memoryInfo.pressure < 50 ? .green : (memoryInfo.pressure < 80 ? .yellow : .red))
                }

                // Pressure bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.2))
                            .frame(height: 8)
                            .cornerRadius(4)

                        Rectangle()
                            .fill(memoryInfo.pressure < 50 ? Color.green : (memoryInfo.pressure < 80 ? Color.yellow : Color.red))
                            .frame(width: geo.size.width * CGFloat(memoryInfo.pressure / 100), height: 8)
                            .cornerRadius(4)
                    }
                }
                .frame(height: 8)

                Text("\u{1f4a1} On macOS, \"used\" RAM is meaningless. What matters is Memory Pressure and Swap.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
            .padding(.vertical, 4)
        }
    }
}

struct SuspiciousProcessesCard: View {
    let processes: [ProcessInfo]
    let onTerminate: (ProcessInfo) -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                    Text("\(processes.count) Suspicious Process(es)")
                        .fontWeight(.medium)
                }

                ForEach(processes.prefix(5)) { process in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(process.name)
                                .fontWeight(.medium)
                            Text("CPU: \(Int(process.cpuPercent))% • RAM: \(process.memoryFormatted)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button("Terminate") {
                            onTerminate(process)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(8)
                    .background(Color.yellow.opacity(0.1))
                    .cornerRadius(8)
                }
            }
        } label: {
            Label("Anomalous Processes", systemImage: "exclamationmark.triangle")
        }
    }
}
