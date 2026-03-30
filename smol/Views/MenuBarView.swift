import SwiftUI

/// Main menu bar popup view - extended version with more info
struct MenuBarView: View {
    @ObservedObject var monitor: SystemMonitor
    @Environment(\.openWindow) private var openWindow
    @State private var topProcesses: [ProcessInfo] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with health status
            headerSection

            Divider()

            // Main metrics with bars
            metricsSection

            // Fans (if present)
            if !monitor.fans.isEmpty {
                Divider()
                fansSection
            }

            Divider()

            // Detailed RAM
            ramDetailSection

            Divider()

            // Top CPU processes
            topProcessesSection

            if !monitor.suspiciousProcesses.isEmpty {
                Divider()
                suspiciousProcessesSection
            }

            Divider()

            // Footer with actions
            footerSection
        }
        .frame(width: 320)
        .padding(.vertical, 8)
        .onAppear {
            updateTopProcesses()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("smol")
                    .font(.system(.headline, design: .rounded))
                    .fontWeight(.bold)

                Text(uptimeText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: monitor.health.iconName)
                        .foregroundColor(monitor.health.color)
                    Text(healthText)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(monitor.health.color)
                }

                if case .warning(let reason) = monitor.health {
                    Text(reason)
                        .font(.caption2)
                        .foregroundColor(.yellow)
                        .lineLimit(1)
                } else if case .critical(let reason) = monitor.health {
                    Text(reason)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var healthText: String {
        switch monitor.health {
        case .healthy: return "Healthy"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }

    private var uptimeText: String {
        let uptime = Foundation.ProcessInfo.processInfo.systemUptime
        let totalMinutes = Int(uptime) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours >= 24 {
            let days = hours / 24
            let remainingHours = hours % 24
            if days == 1 {
                return "Uptime: 1 day, \(remainingHours)h"
            }
            return "Uptime: \(days) days, \(remainingHours)h"
        }
        return "Uptime: \(hours)h \(minutes)m"
    }

    // MARK: - Metrics

    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // CPU with bar
            MetricRowWithBar(
                icon: "cpu",
                label: "CPU",
                value: String(format: "%.0f%% in use", 100 - monitor.cpuIdlePercent),
                progress: (100 - monitor.cpuIdlePercent) / 100,
                color: cpuBarColor
            )

            // Memory Pressure with bar
            MetricRowWithBar(
                icon: "memorychip",
                label: "Pressure",
                value: "\(monitor.memoryInfo.pressureLevel) (\(Int(monitor.memoryInfo.pressure))%)",
                progress: monitor.memoryInfo.pressure / 100,
                color: monitor.memoryInfo.pressure < 50 ? .green : (monitor.memoryInfo.pressure < 80 ? .yellow : .red)
            )

            // Swap
            HStack {
                Image(systemName: "arrow.triangle.swap")
                    .frame(width: 20)
                    .foregroundColor(.secondary)

                Text("Swap")
                    .frame(width: 60, alignment: .leading)

                Spacer()

                if monitor.memoryInfo.swapUsed == 0 {
                    Label("0 MB", systemImage: "checkmark.circle.fill")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.green)
                } else {
                    Label(swapText, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.red)
                }
            }

            // Temperature with trend
            HStack {
                Image(systemName: temperatureIcon)
                    .frame(width: 20)
                    .foregroundColor(temperatureColor)

                Text("Temp")
                    .frame(width: 60, alignment: .leading)

                Spacer()

                HStack(spacing: 4) {
                    Text(String(format: "%.0f°C", monitor.temperature))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(temperatureColor)

                    Text(monitor.temperatureTrend.symbol)
                        .foregroundColor(trendColor)
                        .fontWeight(.bold)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var swapText: String {
        ByteCountFormatter.string(fromByteCount: Int64(monitor.memoryInfo.swapUsed), countStyle: .memory)
    }

    private var temperatureIcon: String {
        if monitor.temperature < 50 {
            return "thermometer.low"
        } else if monitor.temperature < 70 {
            return "thermometer.medium"
        } else {
            return "thermometer.high"
        }
    }

    private var cpuBarColor: Color {
        // Green if low usage, red if high usage
        let cpuUsed = 100 - monitor.cpuIdlePercent
        return cpuUsed < 50 ? .green : (cpuUsed < 80 ? .yellow : .red)
    }

    private var temperatureColor: Color {
        if monitor.temperature < 60 { return .green }
        else if monitor.temperature < 80 { return .yellow }
        else { return .red }
    }

    private var trendColor: Color {
        switch monitor.temperatureTrend {
        case .rising: return .red
        case .falling: return .green
        case .stable: return .secondary
        }
    }

    // MARK: - RAM Detail

    private var ramDetailSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("RAM")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)

                Spacer()

                Text("\(formatBytes(monitor.memoryInfo.used)) / \(formatBytes(monitor.memoryInfo.total))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // RAM bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 6)
                        .cornerRadius(3)

                    Rectangle()
                        .fill(ramBarColor)
                        .frame(width: geo.size.width * ramUsagePercent, height: 6)
                        .cornerRadius(3)
                }
            }
            .frame(height: 6)

            Text("💡 macOS \"used\" RAM includes cache — check Memory Pressure instead")
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var ramUsagePercent: CGFloat {
        guard monitor.memoryInfo.total > 0 else { return 0 }
        return CGFloat(monitor.memoryInfo.used) / CGFloat(monitor.memoryInfo.total)
    }

    private var ramBarColor: Color {
        // Color based on pressure, not on % used
        if monitor.memoryInfo.pressure < 50 { return .green }
        else if monitor.memoryInfo.pressure < 80 { return .yellow }
        else { return .red }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    // MARK: - Fans

    private var fansSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with mode controls
            HStack {
                Image(systemName: "fan")
                    .foregroundColor(.secondary)
                Text("Fans")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)

                Spacer()

                // Mode buttons
                HStack(spacing: 4) {
                    FanModeButton(title: "Auto", isSelected: isSystemMode) {
                        monitor.setFanMode(.system)
                    }
                    FanModeButton(title: "Max", isSelected: isMaxMode) {
                        monitor.setFanMode(.max)
                    }
                }
            }

            // Warning: helper not installed
            if monitor.needsHelperInstallation {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text("Helper required for fan control")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Install") {
                        monitor.installFanHelper()
                    }
                    .font(.caption2)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }
                .padding(8)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(6)
            }

            // Fan list
            ForEach(monitor.fans) { fan in
                FanRow(fan: fan)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var isSystemMode: Bool {
        if case .system = monitor.fanMode { return true }
        return false
    }

    private var isMaxMode: Bool {
        if case .max = monitor.fanMode { return true }
        return false
    }

    // MARK: - Top Processes

    private var topProcessesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Top CPU Processes")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: updateTopProcesses) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }

            ForEach(topProcesses.prefix(3)) { process in
                HStack {
                    Text(process.name)
                        .font(.caption)
                        .lineLimit(1)
                        .frame(maxWidth: 140, alignment: .leading)

                    Spacer()

                    Text(String(format: "%.1f%%", process.cpuPercent))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(process.cpuPercent > 30 ? .orange : .secondary)

                    Text(process.memoryFormatted)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 50, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func updateTopProcesses() {
        let analyzer = ProcessAnalyzer()
        topProcesses = analyzer.getTopProcessesByCPU(limit: 5)
    }

    // MARK: - Suspicious Processes

    private var suspiciousProcessesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                Text("\(monitor.suspiciousProcesses.count) suspicious process(es)")
                    .font(.caption)
                    .fontWeight(.medium)
            }

            ForEach(monitor.suspiciousProcesses.prefix(3)) { process in
                SuspiciousProcessRow(process: process) {
                    monitor.terminateProcess(process)
                }
            }

            if monitor.suspiciousProcesses.count > 3 {
                Button("Show all...") {
                    openWindow(id: "dashboard")
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack(spacing: 12) {
            Button {
                openWindow(id: "dashboard")
            } label: {
                Label("Dashboard", systemImage: "gauge.with.dots.needle.bottom.50percent")
            }
            .buttonStyle(.borderless)

            Button {
                openWindow(id: "cleanup")
            } label: {
                Label("Cleanup", systemImage: "trash")
            }
            .buttonStyle(.borderless)

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .foregroundColor(.red)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Components

/// Metric row with progress bar
struct MetricRowWithBar: View {
    let icon: String
    let label: String
    let value: String
    let progress: Double
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: icon)
                    .frame(width: 20)
                    .foregroundColor(.secondary)

                Text(label)
                    .frame(width: 60, alignment: .leading)

                Spacer()

                Text(value)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(color)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 4)
                        .cornerRadius(2)

                    Rectangle()
                        .fill(color)
                        .frame(width: geo.size.width * min(progress, 1.0), height: 4)
                        .cornerRadius(2)
                }
            }
            .frame(height: 4)
        }
    }
}

/// Row for suspicious process
struct SuspiciousProcessRow: View {
    let process: ProcessInfo
    let onTerminate: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(process.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Label("\(Int(process.cpuPercent))%", systemImage: "cpu")
                    Label(process.memoryFormatted, systemImage: "memorychip")
                    Label(runningTimeText, systemImage: "clock")
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: onTerminate) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color.yellow.opacity(0.1))
        .cornerRadius(6)
    }

    private var runningTimeText: String {
        let minutes = process.cpuTimeMinutes
        if minutes < 60 {
            return String(format: "%.0fm", minutes)
        } else {
            return String(format: "%.1fh", minutes / 60)
        }
    }
}

/// Button for fan mode
struct FanModeButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption2)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.2))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }
}

/// Row for single fan
struct FanRow: View {
    let fan: FanMonitor.FanInfo

    var body: some View {
        HStack {
            Text(fan.name)
                .font(.caption)
                .frame(width: 70, alignment: .leading)

            // RPM bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 6)
                        .cornerRadius(3)

                    Rectangle()
                        .fill(rpmColor)
                        .frame(width: geo.size.width * CGFloat(fan.rpmPercent / 100), height: 6)
                        .cornerRadius(3)
                }
            }
            .frame(height: 6)

            Text("\(fan.currentRPM) RPM")
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(rpmColor)
                .frame(width: 65, alignment: .trailing)
        }
    }

    private var rpmColor: Color {
        if fan.rpmPercent < 30 { return .green }
        else if fan.rpmPercent < 70 { return .yellow }
        else { return .orange }
    }
}

// MARK: - Preview

#Preview {
    MenuBarView(monitor: SystemMonitor())
}
