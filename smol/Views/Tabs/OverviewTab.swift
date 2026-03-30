import SwiftUI

// MARK: - Overview Tab

struct OverviewTab: View {
    @ObservedObject var monitor: SystemMonitor
    @StateObject private var localization = LocalizationManager.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header stato salute - più grande e accattivante
                EnhancedHealthHeader(health: monitor.health, temperature: monitor.temperature)

                // Griglia metriche 2x2
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16)
                ], spacing: 16) {
                    EnhancedMetricCard(
                        title: "CPU",
                        value: String(format: "%.0f%%", 100 - monitor.cpuIdlePercent),
                        subtitle: "overview.in_use".localized(localization),
                        icon: "cpu",
                        color: cpuColor,
                        progress: (100 - monitor.cpuIdlePercent) / 100
                    )

                    EnhancedMetricCard(
                        title: "Memory Pressure",
                        value: monitor.memoryInfo.pressureLevel,
                        subtitle: String(format: "%.0f%%", monitor.memoryInfo.pressure),
                        icon: "memorychip",
                        color: memoryColor,
                        progress: monitor.memoryInfo.pressure / 100
                    )

                    EnhancedMetricCard(
                        title: "Swap",
                        value: swapText,
                        subtitle: monitor.memoryInfo.swapUsed == 0 ? "overview.all_good".localized(localization) : "overview.attention".localized(localization),
                        icon: monitor.memoryInfo.swapUsed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                        color: monitor.memoryInfo.swapUsed == 0 ? .green : .red,
                        progress: nil
                    )

                    EnhancedMetricCard(
                        title: "tab.temperature".localized(localization),
                        value: String(format: "%.0f°C", monitor.temperature),
                        subtitle: trendText,
                        icon: temperatureIcon,
                        color: tempColor,
                        progress: min(monitor.temperature / 100, 1.0)
                    )
                }

                // RAM dettaglio
                RAMDetailView(memoryInfo: monitor.memoryInfo)

                // Processi sospetti (se presenti)
                if !monitor.suspiciousProcesses.isEmpty {
                    SuspiciousProcessesCard(processes: monitor.suspiciousProcesses) { process in
                        monitor.terminateProcess(process)
                    }
                }
            }
            .padding()
        }
    }

    private var cpuColor: Color {
        let cpuUsed = 100 - monitor.cpuIdlePercent
        return cpuUsed < 50 ? .green : (cpuUsed < 80 ? .yellow : .red)
    }

    private var memoryColor: Color {
        monitor.memoryInfo.pressure < 50 ? .green : (monitor.memoryInfo.pressure < 80 ? .yellow : .red)
    }

    private var tempColor: Color {
        monitor.temperature < 60 ? .green : (monitor.temperature < 80 ? .yellow : .red)
    }

    private var temperatureIcon: String {
        if monitor.temperature < 50 { return "thermometer.low" }
        else if monitor.temperature < 70 { return "thermometer.medium" }
        else { return "thermometer.high" }
    }

    private var trendText: String {
        switch monitor.temperatureTrend {
        case .rising: return "overview.rising".localized(localization) + " ↑"
        case .falling: return "overview.falling".localized(localization) + " ↓"
        case .stable: return "overview.stable".localized(localization) + " →"
        }
    }

    private var swapText: String {
        if monitor.memoryInfo.swapUsed == 0 {
            return "0 MB"
        }
        return ByteCountFormatter.string(fromByteCount: Int64(monitor.memoryInfo.swapUsed), countStyle: .memory)
    }
}

/// Header stato salute migliorato
struct EnhancedHealthHeader: View {
    let health: SystemHealth
    let temperature: Double
    @StateObject private var localization = LocalizationManager.shared

    var body: some View {
        HStack(spacing: 16) {
            // Icona animata
            ZStack {
                Circle()
                    .fill(health.color.opacity(0.2))
                    .frame(width: 60, height: 60)

                Image(systemName: health.iconName)
                    .font(.system(size: 28))
                    .foregroundColor(health.color)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(statusTitle)
                    .font(.title2)
                    .fontWeight(.bold)

                Text(health.description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Quick stats
            VStack(alignment: .trailing, spacing: 4) {
                Text(String(format: "%.0f°C", temperature))
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundColor(temperature < 70 ? .green : .orange)

                Text("temp.cpu".localized(localization))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(health.color.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(health.color.opacity(0.3), lineWidth: 1)
                )
        )
    }

    private var statusTitle: String {
        switch health {
        case .healthy: return "overview.system_healthy".localized(localization)
        case .warning: return "overview.warning".localized(localization)
        case .critical: return "overview.critical".localized(localization)
        }
    }
}

/// Card metrica migliorata con barra di progresso
struct EnhancedMetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let color: Color
    let progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(color)

                Spacer()

                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text(value)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundColor(color)

            if let progress = progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.2))
                            .frame(height: 6)

                        RoundedRectangle(cornerRadius: 4)
                            .fill(color)
                            .frame(width: geo.size.width * CGFloat(progress), height: 6)
                    }
                }
                .frame(height: 6)
            }

            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.05), radius: 5, x: 0, y: 2)
        )
    }
}
