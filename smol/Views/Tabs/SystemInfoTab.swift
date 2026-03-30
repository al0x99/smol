import SwiftUI

// MARK: - System Info Tab

struct SystemInfoTab: View {
    @StateObject private var localization = LocalizationManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header con icona Mac
                HStack(spacing: 16) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 48))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue, .purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(getModelName())
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text(getProcessorName())
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.accentColor.opacity(0.1))
                )

                // Specifiche Hardware
                GroupBox {
                    VStack(spacing: 0) {
                        SystemInfoRow(icon: "cpu", label: "system.processor".localized(localization), value: getProcessorName(), color: .orange)
                        Divider().padding(.vertical, 8)
                        SystemInfoRow(icon: "number", label: "system.cores".localized(localization), value: "\(Foundation.ProcessInfo.processInfo.processorCount) core", color: .blue)
                        Divider().padding(.vertical, 8)
                        SystemInfoRow(icon: "memorychip", label: "RAM", value: getTotalRAM(), color: .green)
                    }
                    .padding(.vertical, 8)
                } label: {
                    Label("system.hardware".localized(localization), systemImage: "gearshape.2")
                        .font(.headline)
                }

                // Info Sistema
                GroupBox {
                    VStack(spacing: 0) {
                        SystemInfoRow(icon: "apple.logo", label: "macOS", value: Foundation.ProcessInfo.processInfo.operatingSystemVersionString, color: .gray)
                        Divider().padding(.vertical, 8)
                        SystemInfoRow(icon: "clock", label: "system.uptime".localized(localization), value: getUptime(), color: .purple)
                        Divider().padding(.vertical, 8)
                        SystemInfoRow(icon: "network", label: "system.host_name".localized(localization), value: Foundation.ProcessInfo.processInfo.hostName, color: .teal)
                    }
                    .padding(.vertical, 8)
                } label: {
                    Label("tab.system".localized(localization), systemImage: "laptopcomputer")
                        .font(.headline)
                }

                // Info App con monitoraggio risorse smol
                SmolSelfMonitorView()

                // Footer
                HStack {
                    Spacer()
                    Text("system.made_with".localized(localization))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.top, 8)
            }
            .padding()
        }
    }

    private func getModelName() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }

    private func getProcessorName() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var name = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &name, &size, nil, 0)
        let result = String(cString: name)
        return result.isEmpty ? "Apple Silicon" : result
    }

    private func getTotalRAM() -> String {
        var memSize: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memSize, &size, nil, 0)
        return ByteCountFormatter.string(fromByteCount: Int64(memSize), countStyle: .memory)
    }

    private func getUptime() -> String {
        let uptime = Foundation.ProcessInfo.processInfo.systemUptime
        let totalMinutes = Int(uptime) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours >= 24 {
            let days = hours / 24
            let remainingHours = hours % 24
            if days == 1 {
                return "1 " + "system.day".localized(localization) + ", \(remainingHours)h"
            }
            return "\(days) " + "system.days".localized(localization) + ", \(remainingHours)h"
        }
        return "\(hours)h \(minutes)m"
    }
}

/// Riga info sistema con icona colorata
struct SystemInfoRow: View {
    let icon: String
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(color)
                .frame(width: 24)

            Text(label)
                .foregroundColor(.secondary)

            Spacer()

            Text(value)
                .fontWeight(.medium)
                .textSelection(.enabled)
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .textSelection(.enabled)
        }
    }
}
