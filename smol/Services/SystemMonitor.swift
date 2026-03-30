import Foundation
import Combine

/// Orchestratore principale del monitoraggio sistema
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

    // MARK: - Lifecycle

    init() {
        startMonitoring()
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Public Methods

    func startMonitoring() {
        // Aggiorna ogni 2 secondi
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.updateMetrics()
            }
        }
        // Prima lettura immediata
        updateMetrics()
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    func terminateProcess(_ process: ProcessInfo) {
        kill(process.id, SIGTERM)
        // Rimuovi dalla lista
        suspiciousProcesses.removeAll { $0.id == process.id }
    }

    func setFanMode(_ mode: FanMonitor.FanMode) {
        fanMode = mode
        fanMonitor.setFanMode(mode)
    }

    func setFanRPM(index: Int, rpm: Int) {
        fanMonitor.setFanRPM(index: index, rpm: rpm)
    }

    /// Verifica se l'helper privilegiato deve essere installato
    var needsHelperInstallation: Bool {
        fanMonitor.needsHelperInstallation
    }

    /// Installa l'helper privilegiato (richiede password admin)
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
        // Calcola trend confrontando con la temperatura precedente
        if previousTemperature > 0 {  // Evita confronto con 0 iniziale
            temperatureTrend = newTemp > previousTemperature + 2 ? .rising :
                              newTemp < previousTemperature - 2 ? .falling : .stable
        }
        previousTemperature = newTemp  // Salva il valore corrente per il prossimo ciclo
        temperature = newTemp

        // Processi sospetti
        suspiciousProcesses = processAnalyzer.findSuspiciousProcesses()

        // Ventole
        fans = fanMonitor.getAllFans()

        // Calcola salute complessiva
        health = calculateHealth()

        // Genera alert se necessario
        checkForNewAlerts()
    }

    private func calculateHealth() -> SystemHealth {
        // Critico: swap alto o memory pressure critica
        if memoryInfo.swapUsed > 1_000_000_000 { // > 1GB swap
            return .critical(reason: "Swap elevato: \(ByteCountFormatter.string(fromByteCount: Int64(memoryInfo.swapUsed), countStyle: .memory))")
        }

        if memoryInfo.pressure > 80 {
            return .critical(reason: "Memory pressure critica: \(Int(memoryInfo.pressure))%")
        }

        if temperature > 95 && cpuIdlePercent > 70 {
            return .critical(reason: "Temperatura alta a riposo: \(Int(temperature))°C")
        }

        // Warning: swap presente, pressure media, o processi anomali
        if memoryInfo.swapUsed > 0 {
            return .warning(reason: "Swap in uso")
        }

        if memoryInfo.pressure > 50 {
            return .warning(reason: "Memory pressure media")
        }

        if !suspiciousProcesses.isEmpty {
            return .warning(reason: "\(suspiciousProcesses.count) processo/i sospetto/i")
        }

        if temperature > 80 && cpuIdlePercent > 50 {
            return .warning(reason: "Temperatura elevata")
        }

        return .healthy
    }

    private func checkForNewAlerts() {
        for process in suspiciousProcesses {
            // Evita duplicati
            if !alerts.contains(where: { $0.process.id == process.id }) {
                let alert = ProcessAlert(
                    process: process,
                    reason: "CPU \(Int(process.cpuPercent))% per più di 10 minuti",
                    detectedAt: Date()
                )
                alerts.append(alert)

                // Notifica sistema
                sendNotification(for: alert)
            }
        }
    }

    private func sendNotification(for alert: ProcessAlert) {
        let content = UNMutableNotificationContent()
        content.title = "smol - Processo Sospetto"
        content.body = "\(alert.process.name) sta usando \(Int(alert.process.cpuPercent))% CPU"
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
