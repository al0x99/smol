import Foundation

// MARK: - AI Models

/// Data point with timestamp for historical analysis
struct AIDataPoint {
    let timestamp: Date
    let value: Double
}

/// AI-generated advice
struct AIAdvice: Identifiable {
    let id = UUID()
    let type: AdviceType
    let title: String
    let description: String
    let severity: Severity
    let action: AdviceAction?
    let timestamp: Date

    enum AdviceType: String, CaseIterable {
        case performance = "Performance"
        case memory = "Memory"
        case temperature = "Temperature"
        case process = "Process"
        case battery = "Battery"
        case general = "General"

        var icon: String {
            switch self {
            case .performance: return "gauge.with.dots.needle.67percent"
            case .memory: return "memorychip"
            case .temperature: return "thermometer.high"
            case .process: return "app.badge.checkmark"
            case .battery: return "battery.75"
            case .general: return "lightbulb"
            }
        }
    }

    enum Severity: String, CaseIterable {
        case info = "Info"
        case warning = "Warning"
        case critical = "Critical"

        var sortOrder: Int {
            switch self {
            case .critical: return 3
            case .warning: return 2
            case .info: return 1
            }
        }
    }

    enum AdviceAction {
        case terminateProcess(pid: Int32, name: String)
        case openActivityMonitor
        case clearCache
        case restartApp(name: String)
        case none
    }
}

/// System-detected anomaly
struct AIAnomaly: Identifiable {
    let id = UUID()
    let type: AnomalyType
    let description: String
    let detectedAt: Date
    let confidence: Double // 0-1
    let relatedMetric: String
    let currentValue: Double
    let expectedRange: ClosedRange<Double>

    enum AnomalyType: String, CaseIterable {
        case cpuSpike = "CPU Spike"
        case memoryLeak = "Memory Leak"
        case thermalThrottling = "Thermal Throttling"
        case temperatureSpike = "Temperature Spike"
        case unusualProcess = "Unusual Process"
        case resourceHog = "Resource Hog"
        case pattern = "Pattern Anomaly"

        var icon: String {
            switch self {
            case .cpuSpike: return "bolt.fill"
            case .memoryLeak: return "drop.fill"
            case .thermalThrottling: return "flame.fill"
            case .temperatureSpike: return "thermometer.sun.fill"
            case .unusualProcess: return "questionmark.app"
            case .resourceHog: return "ant.fill"
            case .pattern: return "waveform.path.ecg"
            }
        }
    }
}

/// Generated system report
struct SystemReport: Identifiable {
    let id = UUID()
    let generatedAt: Date
    let summary: String
    let healthScore: Int // 0-100
    let sections: [ReportSection]
    let recommendations: [String]

    struct ReportSection: Identifiable {
        let id = UUID()
        let title: String
        let content: String
        let metrics: [Metric]

        struct Metric {
            let name: String
            let value: String
            let status: Status

            enum Status {
                case good, warning, critical
            }
        }
    }
}

/// Conversation with the AI assistant
struct AIConversation: Identifiable {
    let id = UUID()
    var messages: [Message]

    struct Message: Identifiable {
        let id = UUID()
        let role: Role
        let content: String
        let timestamp: Date
        var resourceCost: ResourceTracker.ResourceCost?
        var backendSource: String?  // "Cloud", "MLX", "Apple AI", "Template"

        enum Role {
            case user
            case assistant
        }

        init(role: Role, content: String, timestamp: Date = Date(), resourceCost: ResourceTracker.ResourceCost? = nil, backendSource: String? = nil) {
            self.role = role
            self.content = content
            self.timestamp = timestamp
            self.resourceCost = resourceCost
            self.backendSource = backendSource
        }
    }
}
