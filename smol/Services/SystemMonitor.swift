import Foundation
import Combine

/// Main system monitoring orchestrator
@MainActor
class SystemMonitor: ObservableObject {
    // MARK: - Published Properties

    @Published var health: SystemHealth = .healthy
    @Published var cpuIdlePercent: Double = 100
    @Published var memoryInfo: MemoryInfo = MemoryInfo(used: 0, total: 0, pressure: 0, swapUsed: 0)
    @Published var temperature: Double = 0
    @Published var temperatureTrend: TemperatureTrend = .stable
    @Published var suspiciousProcesses: [ProcessInfo] = []
    @Published var alerts: [ProcessAlert] = []
    @Published var fans: [FanMonitor.FanInfo] = []
    @Published var fanMode: FanMonitor.FanMode = .system

    enum TemperatureTrend {
        case rising, falling, stable

        var symbol: String {
            switch self {
            case .rising: return "↑"
            case .falling: return "↓"
            case .stable: return "→"
            }
        }
    }

    // MARK: - Private Properties

    private var timer: Timer?
    private var previousTemperature: Double = 0
    private let cpuMonitor = CPUMonitor()
    private let memoryMonitor = MemoryMonitor()
    private let temperatureMonitor = TemperatureMonitor.shared
    private let processAnalyzer = ProcessAnalyzer()
    private let fanMonitor = FanMonitor()

    // MARK: - Computed Properties

    var menuBarText: String {
        let cpuUsed = 100 - cpuIdlePercent
        let cpuText = String(format: "%.0f%%", cpuUsed)
        let tempText = String(format: "%.0f°", temperature)
        return "\(cpuText) \(tempText)"
    }

    /// VoiceOver-friendly summary of the menu-bar widget's current state.
    var menuBarAccessibilityLabel: String {
        let cpuUsed = Int(100 - cpuIdlePercent)
        let temp = Int(temperature)
        return "smol — \(health.description). CPU \(cpuUsed) percent, temperature \(temp) degrees Celsius."
    }

    // MARK: - Lifecycle

    init() {
        startMonitoring()
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Public Methods

    func startMonitoring() {
        // Update every 2 seconds
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.updateMetrics()
            }
        }
        // Immediate first reading
        updateMetrics()
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    func terminateProcess(_ process: ProcessInfo) {
        kill(process.id, SIGTERM)
        // Remove from list
        suspiciousProcesses.removeAll { $0.id == process.id }
    }

    func setFanMode(_ mode: FanMonitor.FanMode) {
        fanMode = mode
        fanMonitor.setFanMode(mode)
    }

    func setFanRPM(index: Int, rpm: Int) {
        fanMonitor.setFanRPM(index: index, rpm: rpm)
    }

    /// Check if the privileged helper needs to be installed
    var needsHelperInstallation: Bool {
        fanMonitor.needsHelperInstallation
    }

    /// Install the privileged helper (requires admin password)
    @discardableResult
    func installFanHelper() -> Bool {
        fanMonitor.installHelper()
    }

    // MARK: - Private Methods

    private func updateMetrics() {
        // CPU
        cpuIdlePercent = cpuMonitor.getIdlePercent()

        // Memory
        memoryInfo = memoryMonitor.getMemoryInfo()

        // Temperature
        let newTemp = temperatureMonitor.getCPUTemperature()
        // Calculate trend by comparing with previous temperature
        if previousTemperature > 0 {  // Avoid comparison with initial 0
            temperatureTrend = newTemp > previousTemperature + 2 ? .rising :
                              newTemp < previousTemperature - 2 ? .falling : .stable
        }
        previousTemperature = newTemp  // Save current value for the next cycle
        temperature = newTemp

        // Suspicious processes
        suspiciousProcesses = processAnalyzer.findSuspiciousProcesses()

        // Fans
        fans = fanMonitor.getAllFans()

        // Calculate overall health
        health = calculateHealth()

        // Generate alerts if necessary
        checkForNewAlerts()
    }

    private func calculateHealth() -> SystemHealth {
        // Critical: heavy swap, critical memory pressure, or hot at idle.
        if memoryInfo.swapUsed > 1_000_000_000 { // > 1 GB swap
            return .critical(reason: "Heavy swap: \(ByteCountFormatter.string(fromByteCount: Int64(memoryInfo.swapUsed), countStyle: .memory))")
        }

        if memoryInfo.pressure > 80 {
            return .critical(reason: "Memory pressure critical: \(Int(memoryInfo.pressure))%")
        }

        if temperature > 95 && cpuIdlePercent > 70 {
            return .critical(reason: "Hot at idle: \(Int(temperature))°C")
        }

        // Warning: swap present, medium pressure, hot under load, or suspicious processes.
        if memoryInfo.swapUsed > 0 {
            return .warning(reason: "Swap in use")
        }

        if memoryInfo.pressure > 50 {
            return .warning(reason: "Memory pressure medium")
        }

        if !suspiciousProcesses.isEmpty {
            let noun = suspiciousProcesses.count == 1 ? "suspicious process" : "suspicious processes"
            return .warning(reason: "\(suspiciousProcesses.count) \(noun)")
        }

        if temperature > 80 && cpuIdlePercent > 50 {
            return .warning(reason: "Elevated temperature")
        }

        return .healthy
    }

    private func checkForNewAlerts() {
        for process in suspiciousProcesses {
            if !alerts.contains(where: { $0.process.id == process.id }) {
                let alert = ProcessAlert(
                    process: process,
                    reason: "CPU \(Int(process.cpuPercent))% for more than 10 minutes",
                    detectedAt: Date()
                )
                alerts.append(alert)
                sendNotification(for: alert)
            }
        }
    }

    private func sendNotification(for alert: ProcessAlert) {
        let content = UNMutableNotificationContent()
        content.title = "smol — Suspicious Process"
        content.body = "\(alert.process.name) is using \(Int(alert.process.cpuPercent))% CPU"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "process-\(alert.process.id)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }
}

import UserNotifications
