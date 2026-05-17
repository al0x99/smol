import SwiftUI
import Combine

// MARK: - Temperature Tab

struct TemperatureTab: View {
    @ObservedObject var monitor: SystemMonitor
    @StateObject private var localization = LocalizationManager.shared
    @State private var sensors: [TemperatureSensor] = []
    @State private var lastUpdate = Date()
    private let temperatureMonitor = TemperatureMonitor.shared

    // Timer for updates
    let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if sensors.isEmpty {
                // No sensors available
                NoSMCAccessView()
            } else {
                // Sensori disponibili
                ScrollView {
                    VStack(spacing: 20) {
                        // Header with status
                        TemperatureHeader(
                            avgCPUTemp: avgCPUTemperature,
                            maxTemp: maxTemperature,
                            sensorCount: sensors.count
                        )

                        // Sensors by category
                        ForEach(orderedCategories, id: \.self) { category in
                            if let categorySensors = sensorsByCategory[category], !categorySensors.isEmpty {
                                TemperatureCategorySection(
                                    category: category,
                                    sensors: categorySensors
                                )
                            }
                        }

                        // Last updated timestamp
                        HStack {
                            Spacer()
                            Text("\("temp.last_updated".localized(localization)): \(lastUpdate, style: .time)")
                        }
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.top, 8)
                    }
                    .padding()
                }
            }
        }
        .onAppear {
            refreshSensors()
        }
        .onReceive(timer) { _ in
            refreshSensors()
        }
    }

    // MARK: - Computed Properties

    private var sensorsByCategory: [TemperatureSensor.SensorCategory: [TemperatureSensor]] {
        Dictionary(grouping: sensors, by: { $0.category })
    }

    private var orderedCategories: [TemperatureSensor.SensorCategory] {
        // Ordine personalizzato: CPU first, poi GPU, poi altri
        let order: [TemperatureSensor.SensorCategory] = [
            .cpuEfficiency, .cpuPerformance, .gpu, .memory,
            .battery, .storage, .airflow, .thunderbolt, .other
        ]
        return order.filter { sensorsByCategory[$0] != nil }
    }

    private var avgCPUTemperature: Double {
        let cpuSensors = sensors.filter {
            $0.category == .cpuEfficiency || $0.category == .cpuPerformance
        }
        guard !cpuSensors.isEmpty else { return 0 }
        return cpuSensors.map { $0.temperature }.reduce(0, +) / Double(cpuSensors.count)
    }

    private var maxTemperature: Double {
        sensors.map { $0.temperature }.max() ?? 0
    }

    // MARK: - Methods

    private func refreshSensors() {
        sensors = temperatureMonitor.getAllSensors()
        lastUpdate = Date()
    }
}

// MARK: - Temperature Header

struct TemperatureHeader: View {
    let avgCPUTemp: Double
    let maxTemp: Double
    let sensorCount: Int
    @StateObject private var localization = LocalizationManager.shared

    var body: some View {
        HStack(spacing: 20) {
            // CPU Avg
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .foregroundColor(cpuColor)
                    Text("CPU")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text(String(format: "%.0f°C", avgCPUTemp))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundColor(cpuColor)
                Text("temp.average".localized(localization))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(cpuColor.opacity(0.1))
            )

            // Max Temp
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "flame")
                        .foregroundColor(maxColor)
                    Text("Max")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text(String(format: "%.0f°C", maxTemp))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundColor(maxColor)
                Text("temp.peak".localized(localization))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(maxColor.opacity(0.1))
            )

            // Sensor Count
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "sensor")
                        .foregroundColor(.green)
                    Text("temp.sensors".localized(localization))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text("\(sensorCount)")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundColor(.green)
                Text("SMC")
                    .font(.caption2)
                    .foregroundColor(.green)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.green.opacity(0.1))
            )
        }
    }

    private var cpuColor: Color {
        if avgCPUTemp < 50 { return .green }
        else if avgCPUTemp < 70 { return .yellow }
        else if avgCPUTemp < 85 { return .orange }
        else { return .red }
    }

    private var maxColor: Color {
        if maxTemp < 60 { return .green }
        else if maxTemp < 80 { return .yellow }
        else if maxTemp < 95 { return .orange }
        else { return .red }
    }
}

// MARK: - Temperature Category Section

struct TemperatureCategorySection: View {
    let category: TemperatureSensor.SensorCategory
    let sensors: [TemperatureSensor]
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header categoria
            Button {
                withAnimation(.spring(response: 0.3)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: category.icon)
                        .foregroundColor(.accentColor)
                        .frame(width: 24)

                    Text(category.rawValue)
                        .font(.headline)
                        .foregroundColor(.primary)

                    Spacer()

                    // Mini stats
                    if let avgTemp = avgTemperature {
                        Text(String(format: "~%.0f°C", avgTemp))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(4)
                    }

                    Text("\(sensors.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            // Sensor list
            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(sensors) { sensor in
                        TemperatureSensorRow(sensor: sensor)
                        if sensor.id != sensors.last?.id {
                            Divider()
                                .padding(.leading, 44)
                        }
                    }
                }
                .background(Color.secondary.opacity(0.03))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private var avgTemperature: Double? {
        guard !sensors.isEmpty else { return nil }
        return sensors.map { $0.temperature }.reduce(0, +) / Double(sensors.count)
    }
}

// MARK: - Temperature Sensor Row

struct TemperatureSensorRow: View {
    let sensor: TemperatureSensor

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(temperatureColor)
                .frame(width: 8, height: 8)

            Text(sensor.name)
                .font(.system(.body, design: .default))
                .lineLimit(1)

            Spacer()

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.1))
                        .frame(height: 4)
                        .cornerRadius(2)

                    Rectangle()
                        .fill(temperatureGradient)
                        .frame(width: geo.size.width * CGFloat(min(sensor.temperature / 100, 1.0)), height: 4)
                        .cornerRadius(2)
                }
            }
            .frame(width: 60, height: 4)

            // Temperature
            Text(String(format: "%.0f°C", sensor.temperature))
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)
                .foregroundColor(temperatureColor)
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var temperatureColor: Color {
        if sensor.temperature < 40 { return .blue }
        else if sensor.temperature < 55 { return .green }
        else if sensor.temperature < 70 { return .yellow }
        else if sensor.temperature < 85 { return .orange }
        else { return .red }
    }

    private var temperatureGradient: LinearGradient {
        LinearGradient(
            colors: [.green, .yellow, .orange, .red],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

// MARK: - No SMC Access View

struct NoSMCAccessView: View {
    @StateObject private var localization = LocalizationManager.shared

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.1))
                    .frame(width: 100, height: 100)

                Image(systemName: "thermometer.slash")
                    .font(.system(size: 50))
                    .foregroundColor(.orange)
            }

            VStack(spacing: 8) {
                Text("temp.no_sensors".localized(localization))
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("temp.no_smc_access".localized(localization))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Info card
            VStack(alignment: .leading, spacing: 12) {
                Label("temp.why_happens".localized(localization), systemImage: "questionmark.circle")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 8) {
                    InfoBullet(text: "temp.smc_requires".localized(localization))
                    InfoBullet(text: "temp.app_no_permissions".localized(localization))
                    InfoBullet(text: "temp.helper_needed".localized(localization))
                }

                Divider()

                Label("temp.thermal_state".localized(localization), systemImage: "thermometer")
                    .font(.headline)

                HStack {
                    let thermalState = Foundation.ProcessInfo.processInfo.thermalState
                    Circle()
                        .fill(thermalStateColor(thermalState))
                        .frame(width: 12, height: 12)
                    Text(thermalStateText(thermalState))
                        .font(.body)
                        .fontWeight(.medium)
                    Spacer()
                    Text("temp.from_macos".localized(localization))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.orange.opacity(0.1))
            )
            .padding(.horizontal, 40)

            Spacer()
        }
    }

    private func thermalStateText(_ state: Foundation.ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "temp.normal".localized(localization)
        case .fair: return "temp.elevated".localized(localization)
        case .serious: return "temp.high".localized(localization)
        case .critical: return "temp.critical".localized(localization)
        @unknown default: return "Unknown"
        }
    }

    private func thermalStateColor(_ state: Foundation.ProcessInfo.ThermalState) -> Color {
        switch state {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .gray
        }
    }
}

struct InfoBullet: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundColor(.orange)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
