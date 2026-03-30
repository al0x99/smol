import Foundation
import Combine
import NaturalLanguage

/// SmartAdvisor - Assistente AI per analisi sistema
/// Usa Apple Silicon Neural Engine per ML on-device
@MainActor
class SmartAdvisor: ObservableObject {
    static let shared = SmartAdvisor()

    // MARK: - Published Properties

    @Published var currentAdvice: [AIAdvice] = []
    @Published var anomalies: [AIAnomaly] = []
    @Published var lastReport: SystemReport?
    @Published var isAnalyzing = false
    @Published var conversation: AIConversation = AIConversation(messages: [])

    // MARK: - Dependencies

    private let anomalyDetector = AnomalyDetector()
    private let reportGenerator = SystemReportGenerator()
    private let nlProcessor = NaturalLanguageProcessor()

    // ML Engines (real ML)
    private let mlEngine = MLAnomalyEngine.shared
    private let llmEngine = LocalLLMEngine.shared

    // ML State
    @Published var mlPrediction: MLAnomalyEngine.AnomalyPrediction?
    @Published var mlModelTrained: Bool = false

    // Historical data for pattern analysis
    private var cpuHistory: [AIDataPoint] = []
    private var memoryHistory: [AIDataPoint] = []
    private var tempHistory: [AIDataPoint] = []
    private let maxHistorySize = 300 // 10 minuti a 2s intervallo

    // MARK: - Public API

    /// Analizza lo stato corrente del sistema e genera consigli
    func analyze(
        cpuUsage: Double,
        memoryPressure: Double,
        memoryUsed: UInt64,
        memoryTotal: UInt64,
        swapUsed: UInt64,
        temperature: Double,
        processes: [ProcessInfo]
    ) {
        isAnalyzing = true

        // Aggiorna storico
        let now = Date()
        cpuHistory.append(AIDataPoint(timestamp: now, value: cpuUsage))
        memoryHistory.append(AIDataPoint(timestamp: now, value: memoryPressure))
        tempHistory.append(AIDataPoint(timestamp: now, value: temperature))

        // Limita dimensione storico
        trimHistory()

        // Genera consigli
        var newAdvice: [AIAdvice] = []
        var newAnomalies: [AIAnomaly] = []

        // 1. Analisi CPU
        newAdvice.append(contentsOf: analyzeCPU(usage: cpuUsage, processes: processes))

        // 2. Analisi Memoria
        newAdvice.append(contentsOf: analyzeMemory(
            pressure: memoryPressure,
            used: memoryUsed,
            total: memoryTotal,
            swap: swapUsed
        ))

        // 3. Analisi Temperatura
        newAdvice.append(contentsOf: analyzeTemperature(temp: temperature, cpuUsage: cpuUsage))

        // 4. Analisi Processi
        newAdvice.append(contentsOf: analyzeProcesses(processes))

        // 5. Rilevamento Anomalie (pattern-based)
        newAnomalies.append(contentsOf: anomalyDetector.detectAnomalies(
            cpuHistory: cpuHistory,
            memoryHistory: memoryHistory,
            tempHistory: tempHistory
        ))

        // 6. ML-based prediction e training data collection
        let prediction = mlEngine.predict(cpu: cpuUsage, memory: memoryPressure, temp: temperature)
        mlPrediction = prediction
        mlModelTrained = mlEngine.isModelTrained

        // Aggiungi campione per training futuro
        // Marca come anomalia se rilevata sia da pattern che da ML
        let isAnomaly = !newAnomalies.isEmpty || prediction.isAnomaly
        mlEngine.addSample(cpu: cpuUsage, memory: memoryPressure, temp: temperature, isAnomaly: isAnomaly)

        // Se ML rileva anomalia, aggiungi ai risultati
        if prediction.isAnomaly && mlEngine.isModelTrained {
            let anomalyType = mapMLAnomalyType(prediction.anomalyType)
            let currentVal: Double
            let expectedRange: ClosedRange<Double>
            let metric: String

            // Determina metrica principale dell'anomalia
            switch prediction.anomalyType {
            case .cpuSpike:
                currentVal = cpuUsage
                expectedRange = 0...prediction.predictedCPU + 25
                metric = "CPU"
            case .memoryLeak:
                currentVal = memoryPressure
                expectedRange = 0...prediction.predictedMemory + 20
                metric = "Memory"
            case .thermalThrottling:
                currentVal = temperature
                expectedRange = 30...prediction.predictedTemp + 15
                metric = "Temperature"
            default:
                currentVal = cpuUsage
                expectedRange = 0...100
                metric = "System"
            }

            newAnomalies.append(AIAnomaly(
                type: anomalyType,
                description: "ML: \(prediction.anomalyType?.rawValue ?? "Anomalia") - Valori previsti: CPU \(Int(prediction.predictedCPU))%, Mem \(Int(prediction.predictedMemory))%, Temp \(Int(prediction.predictedTemp))°C",
                detectedAt: Date(),
                confidence: prediction.confidence,
                relatedMetric: metric,
                currentValue: currentVal,
                expectedRange: expectedRange
            ))
        }

        // Aggiorna stato
        currentAdvice = newAdvice.sorted { $0.severity.sortOrder > $1.severity.sortOrder }
        anomalies = newAnomalies
        isAnalyzing = false
    }

    /// Mappa tipo anomalia ML a tipo sistema
    private func mapMLAnomalyType(_ type: MLAnomalyEngine.AnomalyPrediction.AnomalyType?) -> AIAnomaly.AnomalyType {
        switch type {
        case .cpuSpike: return .cpuSpike
        case .memoryLeak: return .memoryLeak
        case .thermalThrottling: return .temperatureSpike
        case .combined, .none: return .pattern
        }
    }

    /// Processa una query in linguaggio naturale
    func processQuery(_ query: String) -> String {
        // Aggiungi messaggio utente
        let userMessage = AIConversation.Message(role: .user, content: query, timestamp: Date())
        conversation.messages.append(userMessage)

        // Traccia risorse durante elaborazione
        let tracker = ResourceTracker.shared
        tracker.startTracking()

        // Genera risposta
        let response = nlProcessor.processQuery(
            query,
            cpuHistory: cpuHistory,
            memoryHistory: memoryHistory,
            tempHistory: tempHistory,
            currentAdvice: currentAdvice,
            anomalies: anomalies
        )

        // Conta token output approssimati
        let outputTokens = response.split(separator: " ").count
        tracker.addTokens(outputTokens)

        // Ferma tracking e ottieni costo
        let resourceCost = tracker.stopTracking()

        // Aggiungi risposta assistente con costo risorse
        let assistantMessage = AIConversation.Message(
            role: .assistant,
            content: response,
            timestamp: Date(),
            resourceCost: resourceCost
        )
        conversation.messages.append(assistantMessage)

        return response
    }

    /// Genera un report completo del sistema
    func generateReport() -> SystemReport {
        let report = reportGenerator.generate(
            cpuHistory: cpuHistory,
            memoryHistory: memoryHistory,
            tempHistory: tempHistory,
            advice: currentAdvice,
            anomalies: anomalies
        )
        lastReport = report
        return report
    }

    /// Esporta report come testo
    func exportReportAsText() -> String? {
        guard let report = lastReport else {
            let newReport = generateReport()
            return reportGenerator.exportAsText(newReport)
        }
        return reportGenerator.exportAsText(report)
    }

    /// Pulisce la conversazione
    func clearConversation() {
        conversation = AIConversation(messages: [])
    }

    // MARK: - Private Analysis Methods

    private func analyzeCPU(usage: Double, processes: [ProcessInfo]) -> [AIAdvice] {
        var advice: [AIAdvice] = []

        // CPU molto alta
        if usage > 90 {
            // Trova processo colpevole
            if let topProcess = processes.max(by: { $0.cpuPercent < $1.cpuPercent }) {
                advice.append(AIAdvice(
                    type: .performance,
                    title: "CPU al \(Int(usage))%",
                    description: "\(topProcess.name) sta usando \(Int(topProcess.cpuPercent))% CPU. Potrebbe rallentare il sistema.",
                    severity: .critical,
                    action: .terminateProcess(pid: topProcess.id, name: topProcess.name),
                    timestamp: Date()
                ))
            }
        } else if usage > 70 {
            advice.append(AIAdvice(
                type: .performance,
                title: "CPU elevata",
                description: "Uso CPU al \(Int(usage))%. Il sistema sta lavorando intensamente.",
                severity: .warning,
                action: .openActivityMonitor,
                timestamp: Date()
            ))
        }

        // Trend CPU in aumento
        if let trend = calculateTrend(cpuHistory, windowMinutes: 2), trend > 5 {
            advice.append(AIAdvice(
                type: .performance,
                title: "CPU in aumento",
                description: "L'uso CPU è aumentato del \(Int(trend))% negli ultimi 2 minuti.",
                severity: .info,
                action: nil,
                timestamp: Date()
            ))
        }

        return advice
    }

    private func analyzeMemory(pressure: Double, used: UInt64, total: UInt64, swap: UInt64) -> [AIAdvice] {
        var advice: [AIAdvice] = []

        // Memory pressure critica
        if pressure > 80 {
            advice.append(AIAdvice(
                type: .memory,
                title: "Memoria in pressione critica",
                description: "Memory pressure al \(Int(pressure))%. macOS sta comprimendo memoria attivamente. Chiudi app non necessarie.",
                severity: .critical,
                action: .openActivityMonitor,
                timestamp: Date()
            ))
        } else if pressure > 50 {
            advice.append(AIAdvice(
                type: .memory,
                title: "Memoria sotto pressione",
                description: "Memory pressure al \(Int(pressure))%. Il sistema sta gestendo la memoria attivamente.",
                severity: .warning,
                action: nil,
                timestamp: Date()
            ))
        }

        // Swap in uso
        if swap > 0 {
            let swapGB = Double(swap) / 1_000_000_000
            if swapGB > 2 {
                advice.append(AIAdvice(
                    type: .memory,
                    title: "Swap elevato: \(String(format: "%.1f", swapGB)) GB",
                    description: "Il sistema sta usando il disco come memoria. Questo rallenta significativamente le prestazioni.",
                    severity: .critical,
                    action: .openActivityMonitor,
                    timestamp: Date()
                ))
            } else if swapGB > 0.5 {
                advice.append(AIAdvice(
                    type: .memory,
                    title: "Swap in uso",
                    description: "\(String(format: "%.1f", swapGB)) GB di swap attivo. Considera chiudere alcune app.",
                    severity: .warning,
                    action: nil,
                    timestamp: Date()
                ))
            }
        }

        // Memory leak detection (trend crescente costante)
        if let trend = calculateTrend(memoryHistory, windowMinutes: 5), trend > 10 {
            advice.append(AIAdvice(
                type: .memory,
                title: "Possibile memory leak",
                description: "La pressione memoria è aumentata costantemente del \(Int(trend))% in 5 minuti. Un'app potrebbe avere un memory leak.",
                severity: .warning,
                action: .openActivityMonitor,
                timestamp: Date()
            ))
        }

        return advice
    }

    private func analyzeTemperature(temp: Double, cpuUsage: Double) -> [AIAdvice] {
        var advice: [AIAdvice] = []

        // Temperatura critica
        if temp > 95 {
            advice.append(AIAdvice(
                type: .temperature,
                title: "Temperatura critica: \(Int(temp))°C",
                description: "Il Mac potrebbe andare in throttling termico. Riduci il carico di lavoro o migliora la ventilazione.",
                severity: .critical,
                action: nil,
                timestamp: Date()
            ))
        } else if temp > 85 {
            advice.append(AIAdvice(
                type: .temperature,
                title: "Temperatura elevata: \(Int(temp))°C",
                description: "La CPU si sta scaldando. Normale sotto carico intenso.",
                severity: .warning,
                action: nil,
                timestamp: Date()
            ))
        }

        // Temperatura alta con CPU bassa = problema
        if temp > 80 && cpuUsage < 30 {
            advice.append(AIAdvice(
                type: .temperature,
                title: "Temperatura anomala",
                description: "Temperatura \(Int(temp))°C con CPU al \(Int(cpuUsage))%. Potrebbe esserci un problema di ventilazione o processo nascosto.",
                severity: .warning,
                action: .openActivityMonitor,
                timestamp: Date()
            ))
        }

        // Trend temperatura in rapido aumento
        if let trend = calculateTrend(tempHistory, windowMinutes: 1), trend > 10 {
            advice.append(AIAdvice(
                type: .temperature,
                title: "Temperatura in rapido aumento",
                description: "La temperatura è aumentata di \(Int(trend))°C nell'ultimo minuto.",
                severity: .info,
                action: nil,
                timestamp: Date()
            ))
        }

        return advice
    }

    private func analyzeProcesses(_ processes: [ProcessInfo]) -> [AIAdvice] {
        var advice: [AIAdvice] = []

        // Processi con CPU time molto alto (running da molto)
        for process in processes {
            if process.cpuTimeMinutes > 60 && process.cpuPercent > 20 {
                advice.append(AIAdvice(
                    type: .process,
                    title: "\(process.name) attivo da molto",
                    description: "In esecuzione con \(Int(process.cpuPercent))% CPU da \(Int(process.cpuTimeMinutes)) minuti. Potrebbe essere bloccato.",
                    severity: process.cpuPercent > 50 ? .warning : .info,
                    action: .terminateProcess(pid: process.id, name: process.name),
                    timestamp: Date()
                ))
            }
        }

        // Troppi processi ad alta CPU
        let highCPUProcesses = processes.filter { $0.cpuPercent > 30 }
        if highCPUProcesses.count > 3 {
            advice.append(AIAdvice(
                type: .process,
                title: "\(highCPUProcesses.count) processi ad alta CPU",
                description: "Più processi competono per le risorse CPU. Considera chiudere quelli non necessari.",
                severity: .warning,
                action: .openActivityMonitor,
                timestamp: Date()
            ))
        }

        return advice
    }

    // MARK: - Helpers

    private func trimHistory() {
        if cpuHistory.count > maxHistorySize {
            cpuHistory.removeFirst(cpuHistory.count - maxHistorySize)
        }
        if memoryHistory.count > maxHistorySize {
            memoryHistory.removeFirst(memoryHistory.count - maxHistorySize)
        }
        if tempHistory.count > maxHistorySize {
            tempHistory.removeFirst(tempHistory.count - maxHistorySize)
        }
    }

    /// Calcola trend (cambio percentuale) in una finestra temporale
    private func calculateTrend(_ history: [AIDataPoint], windowMinutes: Int) -> Double? {
        guard history.count >= 2 else { return nil }

        let windowStart = Date().addingTimeInterval(-Double(windowMinutes * 60))
        let windowData = history.filter { $0.timestamp >= windowStart }

        guard let first = windowData.first, let last = windowData.last else { return nil }

        return last.value - first.value
    }
}
