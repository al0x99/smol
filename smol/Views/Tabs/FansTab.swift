import SwiftUI

// MARK: - Fans Tab

struct FansTab: View {
    @ObservedObject var monitor: SystemMonitor
    @StateObject private var localization = LocalizationManager.shared
    @State private var selectedMode: FanModeOption = .system

    enum FanModeOption: String, CaseIterable {
        case system = "System"
        case max = "Max"
        case autoMax = "Auto Max"

        func description(_ loc: LocalizationManager) -> String {
            switch self {
            case .system: return "fans.system_control".localized(loc)
            case .max: return "fans.max_control".localized(loc)
            case .autoMax: return "fans.automax_control".localized(loc)
            }
        }
    }

    /// Verifica se tutte le ventole sono a 0 RPM
    private var allFansOff: Bool {
        !monitor.fans.isEmpty && monitor.fans.allSatisfy { $0.currentRPM == 0 }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if monitor.fans.isEmpty {
                    ContentUnavailableView(
                        "fans.no_fans".localized(localization),
                        systemImage: "fan.slash",
                        description: Text("fans.no_fans_desc".localized(localization))
                    )
                } else {
                    // Avviso ventole spente (Apple Silicon)
                    if allFansOff {
                        FansOffWarningView()
                    }

                    // Controlli modalità
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("fans.mode".localized(localization), selection: $selectedMode) {
                                ForEach(FanModeOption.allCases, id: \.self) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: selectedMode) { _, newValue in
                                applyFanMode(newValue)
                            }

                            Text(selectedMode.description(localization))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 8)
                    } label: {
                        Label("fans.control_mode".localized(localization), systemImage: "slider.horizontal.3")
                    }

                    // Lista ventole
                    GroupBox {
                        VStack(spacing: 16) {
                            ForEach(monitor.fans) { fan in
                                FanDetailRow(fan: fan)
                            }
                        }
                        .padding(.vertical, 8)
                    } label: {
                        HStack {
                            Label("fans.fans".localized(localization), systemImage: "fan")
                            Spacer()
                            if allFansOff {
                                Text("fans.off".localized(localization))
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.2))
                                    .cornerRadius(4)
                            }
                        }
                    }

                    // Info
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            InfoRow(label: "fans.fan_count".localized(localization), value: "\(monitor.fans.count)")
                            if let maxRPM = monitor.fans.map({ $0.maxRPM }).max() {
                                InfoRow(label: "fans.max_rpm".localized(localization), value: "\(maxRPM)")
                            }
                            if !allFansOff && !monitor.fans.isEmpty {
                                let avgRPM = monitor.fans.map({ $0.currentRPM }).reduce(0, +) / monitor.fans.count
                                InfoRow(label: "fans.avg_rpm".localized(localization), value: "\(avgRPM)")
                            }
                        }
                        .padding(.vertical, 4)
                    } label: {
                        Label("fans.info".localized(localization), systemImage: "info.circle")
                    }
                }
            }
            .padding()
        }
    }

    private func applyFanMode(_ mode: FanModeOption) {
        switch mode {
        case .system:
            monitor.setFanMode(.system)
        case .max:
            monitor.setFanMode(.max)
        case .autoMax:
            monitor.setFanMode(.autoMax)
        }
    }
}

struct FanDetailRow: View {
    let fan: FanMonitor.FanInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "fan")
                    .foregroundColor(.accentColor)
                Text(fan.name)
                    .fontWeight(.medium)
                Spacer()
                Text("\(fan.currentRPM) RPM")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(rpmColor)
            }

            // Barra RPM grande
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 12)
                        .cornerRadius(6)

                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [.green, .yellow, .orange],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * CGFloat(fan.rpmPercent / 100), height: 12)
                        .cornerRadius(6)
                }
            }
            .frame(height: 12)

            HStack {
                Text("Min: \(fan.minRPM)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(fan.rpmPercent))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("Max: \(fan.maxRPM)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }

    private var rpmColor: Color {
        if fan.rpmPercent < 30 { return .green }
        else if fan.rpmPercent < 70 { return .yellow }
        else { return .orange }
    }
}

/// Info quando le ventole sono spente (Apple Silicon) - controlli comunque disponibili
struct FansOffWarningView: View {
    @StateObject private var localization = LocalizationManager.shared
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            Button {
                withAnimation(.spring(response: 0.3)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "fan.fill")
                        .font(.title2)
                        .foregroundColor(.green)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("fans.sleep_mode".localized(localization))
                            .font(.headline)
                            .foregroundColor(.primary)

                        Text("fans.sleep_desc".localized(localization))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            .buttonStyle(.plain)

            // Contenuto espandibile
            if isExpanded {
                VStack(alignment: .leading, spacing: 16) {
                    Divider()

                    // Spiegazione
                    VStack(alignment: .leading, spacing: 8) {
                        Label("fans.why_fans_off".localized(localization), systemImage: "questionmark.circle")
                            .font(.subheadline)
                            .fontWeight(.semibold)

                        Text("fans.why_fans_off_desc".localized(localization))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label("fans.when_control_works".localized(localization), systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.green)

                        Text("fans.when_control_works_desc".localized(localization))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label("fans.is_problem".localized(localization), systemImage: "checkmark.shield")
                            .font(.subheadline)
                            .fontWeight(.semibold)

                        Text("fans.is_problem_desc".localized(localization))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Stato attuale
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("fans.cold_status".localized(localization))
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                    .padding(8)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(8)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.green.opacity(0.1))
                .stroke(Color.green.opacity(0.3), lineWidth: 1)
        )
    }
}
