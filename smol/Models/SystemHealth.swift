import SwiftUI

/// Represents the system health state
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
        case .healthy: return "System healthy"
        case .warning(let reason): return "Warning: \(reason)"
        case .critical(let reason): return "Critical: \(reason)"
        }
    }
}

/// System memory information
struct MemoryInfo {
    let used: UInt64           // Used bytes
    let total: UInt64          // Total bytes
    let pressure: Double       // 0-100%
    let swapUsed: UInt64       // Swap bytes

    var pressureLevel: String {
        if pressure < 50 { return "LOW" }
        if pressure < 80 { return "MEDIUM" }
        return "HIGH"
    }

    var isHealthy: Bool {
        pressure < 50 && swapUsed == 0
    }
}

/// Process information
struct ProcessInfo: Identifiable {
    let id: Int32              // PID
    let name: String
    let cpuPercent: Double
    let memoryBytes: UInt64
    let startTime: Date
    let cpuTimeMinutes: Double // CPU minutes consumed

    var isAnomaly: Bool {
        // Alert if CPU > 30% for a process running more than 10 minutes
        let runningMinutes = Date().timeIntervalSince(startTime) / 60
        return cpuPercent > 30 && runningMinutes > 10
    }

    var memoryFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(memoryBytes), countStyle: .memory)
    }
}

/// Alert for anomalous process
struct ProcessAlert: Identifiable {
    let id = UUID()
    let process: ProcessInfo
    let reason: String
    let detectedAt: Date
}
