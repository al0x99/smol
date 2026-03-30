import SwiftUI

// MARK: - Alerts Tab

struct AlertsTab: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var settings = AlertSettings.shared
    @StateObject private var localization = LocalizationManager.shared
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // Header sempre visibile
            HStack {
                if monitor.alerts.isEmpty {
                    Label("alerts.monitoring_active".localized(localization), systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundColor(.green)
                } else {
                    Label("\(monitor.alerts.count) " + "alerts.active_alerts".localized(localization), systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundColor(.orange)
                }

                Spacer()

                Button {
                    withAnimation(.spring(response: 0.3)) {
                        showSettings.toggle()
                    }
                } label: {
                    Label("tab.settings".localized(localization), systemImage: showSettings ? "gearshape.fill" : "gearshape")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding()

            Divider()

            if showSettings {
                // Settings section
                AlertSettingsView(settings: settings)
                    .transition(.move(edge: .top).combined(with: .opacity))

                Divider()
            }

            if monitor.alerts.isEmpty {
                // Stato vuoto migliorato
                VStack(spacing: 24) {
                    Spacer()

                    ZStack {
                        Circle()
                            .fill(Color.green.opacity(0.1))
                            .frame(width: 100, height: 100)

                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 50))
                            .foregroundColor(.green)
                    }

                    VStack(spacing: 8) {
                        Text("alerts.no_alerts".localized(localization))
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text("alerts.no_anomalies_desc".localized(localization))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    // Info card with current thresholds
                    VStack(alignment: .leading, spacing: 12) {
                        Label("alerts.what_monitors".localized(localization), systemImage: "info.circle")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 8) {
                            AlertInfoRow(icon: "cpu", text: "alerts.cpu_threshold_desc".localized(localization) + " \(Int(settings.cpuThreshold))%")
                            AlertInfoRow(icon: "clock", text: "alerts.running_time_desc".localized(localization) + " \(Int(settings.minRunningMinutes)) " + "alerts.minutes".localized(localization))
                            AlertInfoRow(icon: "timer", text: "alerts.cpu_time_desc".localized(localization) + " \(Int(settings.cpuTimeThreshold)) " + "alerts.minutes".localized(localization))
                            AlertInfoRow(icon: "eye", text: "alerts.known_bloatware".localized(localization))
                        }
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.blue.opacity(0.1))
                    )
                    .padding(.horizontal, 40)

                    Spacer()
                }
            } else {
                // Improved alert list
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(monitor.alerts) { alert in
                            EnhancedAlertRow(alert: alert)
                        }
                    }
                    .padding()
                }
            }
        }
    }
}

// MARK: - Alert Settings View

struct AlertSettingsView: View {
    @ObservedObject var settings: AlertSettings
    @StateObject private var localization = LocalizationManager.shared
    @State private var expandedTip: String? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Presets
                VStack(alignment: .leading, spacing: 12) {
                    Label("alerts.quick_presets".localized(localization), systemImage: "wand.and.stars")
                        .font(.headline)

                    HStack(spacing: 12) {
                        ForEach(AlertSettings.presets, id: \.name) { preset in
                            PresetButton(
                                preset: preset,
                                isSelected: isPresetSelected(preset)
                            ) {
                                withAnimation(.spring(response: 0.3)) {
                                    settings.applyPreset(preset)
                                }
                            }
                        }
                    }
                }

                Divider()

                // Soglia CPU
                ThresholdSlider(
                    title: "alerts.cpu_threshold".localized(localization),
                    value: $settings.cpuThreshold,
                    range: 10...80,
                    unit: "%",
                    icon: "cpu",
                    color: .orange,
                    tip: AlertSettings.cpuThresholdTip,
                    expandedTip: $expandedTip
                )

                // Minimum running time
                ThresholdSlider(
                    title: "alerts.min_running_time".localized(localization),
                    value: $settings.minRunningMinutes,
                    range: 1...60,
                    unit: " min",
                    icon: "clock",
                    color: .blue,
                    tip: AlertSettings.minRunningTip,
                    expandedTip: $expandedTip
                )

                // Soglia CPU Time
                ThresholdSlider(
                    title: "alerts.cpu_time_threshold".localized(localization),
                    value: $settings.cpuTimeThreshold,
                    range: 1...30,
                    unit: " min",
                    icon: "timer",
                    color: .purple,
                    tip: AlertSettings.cpuTimeTip,
                    expandedTip: $expandedTip
                )

                // Pulsante reset
                Button {
                    withAnimation(.spring(response: 0.3)) {
                        settings.resetToDefaults()
                    }
                } label: {
                    Label("alerts.reset_defaults".localized(localization), systemImage: "arrow.counterclockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding()
        }
        .frame(maxHeight: 400)
        .background(Color.secondary.opacity(0.05))
    }

    private func isPresetSelected(_ preset: AlertSettings.Preset) -> Bool {
        return settings.cpuThreshold == preset.cpuThreshold &&
               settings.minRunningMinutes == preset.minRunningMinutes &&
               settings.cpuTimeThreshold == preset.cpuTimeThreshold
    }
}

// MARK: - Preset Button

struct PresetButton: View {
    let preset: AlertSettings.Preset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: preset.icon)
                    .font(.title2)

                Text(preset.name)
                    .font(.caption)
                    .fontWeight(.medium)

                Text(preset.description)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .foregroundColor(isSelected ? .accentColor : .primary)
    }
}

// MARK: - Threshold Slider

struct ThresholdSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String
    let icon: String
    let color: Color
    let tip: String
    @Binding var expandedTip: String?

    private var isExpanded: Bool {
        expandedTip == title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .frame(width: 24)

                Text(title)
                    .fontWeight(.medium)

                Spacer()

                Text("\(Int(value))\(unit)")
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.semibold)
                    .foregroundColor(color)

                Button {
                    withAnimation(.spring(response: 0.3)) {
                        if isExpanded {
                            expandedTip = nil
                        } else {
                            expandedTip = title
                        }
                    }
                } label: {
                    Image(systemName: isExpanded ? "questionmark.circle.fill" : "questionmark.circle")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Slider
            Slider(value: $value, in: range, step: 1)
                .tint(color)

            // Range labels
            HStack {
                Text("\(Int(range.lowerBound))\(unit)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(range.upperBound))\(unit)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // Tip espandibile
            if isExpanded {
                Text(tip)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(color.opacity(0.1))
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

struct AlertInfoRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(.blue)
                .frame(width: 20)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

struct EnhancedAlertRow: View {
    let alert: ProcessAlert

    var body: some View {
        HStack(spacing: 16) {
            // Icona
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.2))
                    .frame(width: 44, height: 44)

                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.title3)
            }

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(alert.process.name)
                    .font(.headline)

                Text(alert.reason)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    Label("PID: \(alert.process.id)", systemImage: "number")
                    Label(alert.process.memoryFormatted, systemImage: "memorychip")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            // Timestamp
            VStack(alignment: .trailing, spacing: 4) {
                Text(alert.detectedAt, style: .time)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(alert.detectedAt, style: .date)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                )
        )
    }
}

/// Pill for compact statistics
struct StatPill: View {
    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
            Text(value)
                .fontWeight(.semibold)
            Text(label)
                .foregroundColor(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.1))
        .foregroundColor(color)
        .cornerRadius(12)
    }
}
