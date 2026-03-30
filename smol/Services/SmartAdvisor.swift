import Foundation
import Combine
import NaturalLanguage

/// SmartAdvisor - AI assistant for system analysis
/// Uses Apple Silicon Neural Engine for on-device ML
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

    /// Analyze the current system state and generate advice
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

        // Update history
        let now = Date()
        cpuHistory.append(AIDataPoint(timestamp: now, value: cpuUsage))
        memoryHistory.append(AIDataPoint(timestamp: now, value: memoryPressure))
        tempHistory.append(AIDataPoint(timestamp: now, value: temperature))

        // Limit history size
        trimHistory()

        // Generate advice
        var newAdvice: [AIAdvice] = []
        var newAnomalies: [AIAnomaly] = []

        // 1. CPU analysis
        newAdvice.append(contentsOf: analyzeCPU(usage: cpuUsage, processes: processes))

        // 2. Memory analysis
        newAdvice.append(contentsOf: analyzeMemory(
            pressure: memoryPressure,
            used: memoryUsed,
            total: memoryTotal,
            swap: swapUsed
        ))

        // 3. Temperature analysis
        newAdvice.append(contentsOf: analyzeTemperature(temp: temperature, cpuUsage: cpuUsage))

        // 4. Process analysis
        newAdvice.append(contentsOf: analyzeProcesses(processes))

        // 5. Anomaly detection (pattern-based)
        newAnomalies.append(contentsOf: anomalyDetector.detectAnomalies(
            cpuHistory: cpuHistory,
            memoryHistory: memoryHistory,
            tempHistory: tempHistory
        ))

        // 6. ML-based prediction e training data collection
        let prediction = mlEngine.predict(cpu: cpuUsage, memory: memoryPressure, temp: temperature)
        mlPrediction = prediction
        mlModelTrained = mlEngine.isModelTrained

        // Add sample for future training
        // Mark as anomaly if detected by both pattern and ML
        let isAnomaly = !newAnomalies.isEmpty || prediction.isAnomaly
        mlEngine.addSample(cpu: cpuUsage, memory: memoryPressure, temp: temperature, isAnomaly: isAnomaly)

        // If ML detects an anomaly, add to results
        if prediction.isAnomaly && mlEngine.isModelTrained {
            let anomalyType = mapMLAnomalyType(prediction.anomalyType)
            let currentVal: Double
            let expectedRange: ClosedRange<Double>
            let metric: String

            // Determine main metric of the anomaly
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

        // Update state
        currentAdvice = newAdvice.sorted { $0.severity.sortOrder > $1.severity.sortOrder }
        anomalies = newAnomalies
        isAnalyzing = false
    }

    /// Map ML anomaly type to system type
    private func mapMLAnomalyType(_ type: MLAnomalyEngine.AnomalyPrediction.AnomalyType?) -> AIAnomaly.AnomalyType {
        switch type {
        case .cpuSpike: return .cpuSpike
        case .memoryLeak: return .memoryLeak
        case .thermalThrottling: return .temperatureSpike
        case .combined, .none: return .pattern
        }
    }

    /// Process a natural language query
    func processQuery(_ query: String) -> String {
        // Add user message
        let userMessage = AIConversation.Message(role: .user, content: query, timestamp: Date())
        conversation.messages.append(userMessage)

        // Track resources during processing
        let tracker = ResourceTracker.shared
        tracker.startTracking()

        // Generate response
        let response = nlProcessor.processQuery(
            query,
            cpuHistory: cpuHistory,
            memoryHistory: memoryHistory,
            tempHistory: tempHistory,
            currentAdvice: currentAdvice,
            anomalies: anomalies
        )

        // Approximate output token count
        let outputTokens = response.split(separator: " ").count
        tracker.addTokens(outputTokens)

        // Stop tracking and get cost
        let resourceCost = tracker.stopTracking()

        // Add assistant response with resource cost
        let assistantMessage = AIConversation.Message(
            role: .assistant,
            content: response,
            timestamp: Date(),
            resourceCost: resourceCost
        )
        conversation.messages.append(assistantMessage)

        return response
    }

    /// Generate a comprehensive system report
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

    /// Export report as text
    func exportReportAsText() -> String? {
        guard let report = lastReport else {
            let newReport = generateReport()
            return reportGenerator.exportAsText(newReport)
        }
        return reportGenerator.exportAsText(report)
    }

    /// Clear the conversation
    func clearConversation() {
        conversation = AIConversation(messages: [])
    }

    // MARK: - Private Analysis Methods

    private func analyzeCPU(usage: Double, processes: [ProcessInfo]) -> [AIAdvice] {
        var advice: [AIAdvice] = []

        // CPU very high
        if usage > 90 {
            // Find the culprit process
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

        // CPU trend increasing
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

        // Critical memory pressure
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

        // Swap in use
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

        // Memory leak detection (consistently increasing trend)
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

        // Critical temperature
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

        // High temperature with low CPU = problem
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

        // Processes with very high CPU time (running for a long time)
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

    /// Calculate trend (percentage change) in a time window
    private func calculateTrend(_ history: [AIDataPoint], windowMinutes: Int) -> Double? {
        guard history.count >= 2 else { return nil }

        let windowStart = Date().addingTimeInterval(-Double(windowMinutes * 60))
        let windowData = history.filter { $0.timestamp >= windowStart }

        guard let first = windowData.first, let last = windowData.last else { return nil }

        return last.value - first.value
    }
}
