import SwiftUI

/// Rappresenta lo stato di salute del sistema
enum SystemHealth: Equatable {
    case healthy
    case warning(reason: String)
    case critical(reason: String)

    var color: Color {
        switch self {
        case .healthy: return .green
        case .warning: return .yellow
        case .critical: return .red
        }
    }

    var iconName: String {
        switch self {
        case .healthy: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.circle.fill"
        }
    }

    var description: String {
        switch self {
        case .healthy: return "Sistema OK"
        case .warning(let reason): return "Attenzione: \(reason)"
        case .critical(let reason): return "Critico: \(reason)"
        }
    }
}

/// Informazioni sulla memoria di sistema
struct MemoryInfo {
    let used: UInt64           // Bytes usati
    let total: UInt64          // Bytes totali
    let pressure: Double       // 0-100%
    let swapUsed: UInt64       // Bytes swap

    var pressureLevel: String {
        if pressure < 50 { return "LOW" }
        if pressure < 80 { return "MEDIUM" }
        return "HIGH"
    }

    var isHealthy: Bool {
        pressure < 50 && swapUsed == 0
    }
}

/// Informazioni su un processo
struct ProcessInfo: Identifiable {
    let id: Int32              // PID
    let name: String
    let cpuPercent: Double
    let memoryBytes: UInt64
    let startTime: Date
    let cpuTimeMinutes: Double // Minuti CPU consumati

    var isAnomaly: Bool {
        // Alert se CPU > 30% per processo che gira da più di 10 minuti
        let runningMinutes = Date().timeIntervalSince(startTime) / 60
        return cpuPercent > 30 && runningMinutes > 10
    }

    var memoryFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(memoryBytes), countStyle: .memory)
    }
}

/// Alert per processo anomalo
struct ProcessAlert: Identifiable {
    let id = UUID()
    let process: ProcessInfo
    let reason: String
    let detectedAt: Date
}
