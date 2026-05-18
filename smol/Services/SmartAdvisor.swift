import Foundation
import Combine
import NaturalLanguage
import os

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

    // Streaming state
    @Published var streamingText: String = ""
    @Published var isStreaming: Bool = false
    @Published var streamingBackend: String?

    // Historical data for pattern analysis
    private var cpuHistory: [AIDataPoint] = []
    private var memoryHistory: [AIDataPoint] = []
    private var tempHistory: [AIDataPoint] = []
    private let maxHistorySize = 300 // 10 minutes at 2-second interval

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

            // Determine main metric of the anomaly. Each branch builds
            // an "expected range" anchored at a sensible floor and
            // extended by a fixed margin above the model's prediction.
            // We defensively keep `upper >= lower` because an
            // under-trained model can briefly emit negative or
            // implausibly low predictions, and a `lower > upper`
            // `ClosedRange.init` would trap.
            switch prediction.anomalyType {
            case .cpuSpike:
                currentVal = cpuUsage
                expectedRange = 0 ... max(0, prediction.predictedCPU + 25)
                metric = "CPU"
            case .memoryLeak:
                currentVal = memoryPressure
                expectedRange = 0 ... max(0, prediction.predictedMemory + 20)
                metric = "Memory"
            case .thermalThrottling:
                currentVal = temperature
                expectedRange = 30 ... max(30, prediction.predictedTemp + 15)
                metric = "Temperature"
            default:
                currentVal = cpuUsage
                expectedRange = 0...100
                metric = "System"
            }

            newAnomalies.append(AIAnomaly(
                type: anomalyType,
                description: "ML: \(prediction.anomalyType?.rawValue ?? "Anomaly") — Expected values: CPU \(Int(prediction.predictedCPU))%, Mem \(Int(prediction.predictedMemory))%, Temp \(Int(prediction.predictedTemp))°C",
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

    /// Process a natural language query with streaming support.
    /// Tries real LLM backends first (with streaming), falls back to templates.
    func processQuery(_ query: String) async -> String {
        // Add user message
        let userMessage = AIConversation.Message(role: .user, content: query, timestamp: Date())
        conversation.messages.append(userMessage)

        // Track resources during processing
        let tracker = ResourceTracker.shared
        tracker.startTracking()

        // Build system context for the LLM
        let systemContext = buildSystemContextPrompt()
        var response: String
        var backendUsed = "Template"

        // Reset streaming state
        streamingText = ""
        isStreaming = true
        streamingBackend = nil

        // Try streaming LLM backend first
        do {
            let config = GenerationConfig(
                maxTokens: 512,
                temperature: 0.7,
                topP: 0.9,
                systemPrompt: systemContext
            )

            let (stream, backend) = try await LLMInferenceManager.shared.generateStreamingWithFallback(
                prompt: query,
                config: config
            )
            backendUsed = backend
            streamingBackend = backend

            var accumulated = ""
            for try await token in stream {
                accumulated += token
                streamingText = accumulated
            }
            response = accumulated

        } catch {
            // Try non-streaming fallback
            do {
                let config = GenerationConfig(
                    maxTokens: 512,
                    temperature: 0.7,
                    topP: 0.9,
                    systemPrompt: systemContext
                )
                let result = try await LLMInferenceManager.shared.generateWithFallback(
                    prompt: query,
                    config: config
                )
                response = result.response.text
                backendUsed = result.backend
            } catch {
                // Fall back to template-based response
                SmolLog.ai.info("LLM backends unavailable, using templates: \(error.localizedDescription)")
                response = nlProcessor.processQuery(
                    query,
                    cpuHistory: cpuHistory,
                    memoryHistory: memoryHistory,
                    tempHistory: tempHistory,
                    currentAdvice: currentAdvice,
                    anomalies: anomalies
                )
            }
        }

        // Stop streaming
        isStreaming = false
        streamingText = ""
        streamingBackend = nil

        // Approximate output token count
        let outputTokens = response.split(separator: " ").count
        tracker.addTokens(outputTokens)

        // Stop tracking and get cost
        let resourceCost = tracker.stopTracking()

        // Add assistant response with resource cost and backend source
        let assistantMessage = AIConversation.Message(
            role: .assistant,
            content: response,
            timestamp: Date(),
            resourceCost: resourceCost,
            backendSource: backendUsed
        )
        conversation.messages.append(assistantMessage)

        return response
    }

    /// Cancel the current generation
    func cancelGeneration() {
        LLMInferenceManager.shared.cancelGeneration()
        isStreaming = false
        streamingText = ""
    }

    /// Build a system prompt with current system state for the LLM
    private func buildSystemContextPrompt() -> String {
        let cpu = cpuHistory.last?.value ?? 0
        let mem = memoryHistory.last?.value ?? 0
        let temp = tempHistory.last?.value ?? 0

        var context = """
        You are smol, an AI assistant built into a macOS system monitoring app.
        Current system state:
        - CPU: \(Int(cpu))%
        - Memory Pressure: \(Int(mem))%
        - Temperature: \(Int(temp))°C
        """

        if !anomalies.isEmpty {
            context += "\n- Active anomalies: \(anomalies.map { $0.description }.joined(separator: "; "))"
        }

        if !currentAdvice.isEmpty {
            context += "\n- Active advice: \(currentAdvice.prefix(3).map { $0.title }.joined(separator: ", "))"
        }

        context += "\n\nRespond concisely and helpfully. Match the user's language."
        return context
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
            if let topProcess = processes.max(by: { $0.cpuPercent < $1.cpuPercent }) {
                advice.append(AIAdvice(
                    type: .performance,
                    title: "CPU at \(Int(usage))%",
                    description: "\(topProcess.name) is using \(Int(topProcess.cpuPercent))% CPU. It may be slowing the system down.",
                    severity: .critical,
                    action: .terminateProcess(pid: topProcess.id, name: topProcess.name),
                    timestamp: Date()
                ))
            }
        } else if usage > 70 {
            advice.append(AIAdvice(
                type: .performance,
                title: "Elevated CPU",
                description: "CPU at \(Int(usage))%. The system is under heavy load.",
                severity: .warning,
                action: .openActivityMonitor,
                timestamp: Date()
            ))
        }

        // CPU trend rising
        if let trend = calculateTrend(cpuHistory, windowMinutes: 2), trend > 5 {
            advice.append(AIAdvice(
                type: .performance,
                title: "CPU rising",
                description: "CPU usage rose by \(Int(trend))% in the last 2 minutes.",
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
                title: "Memory under critical pressure",
                description: "Memory pressure at \(Int(pressure))%. macOS is actively compressing memory. Close apps you don't need.",
                severity: .critical,
                action: .openActivityMonitor,
                timestamp: Date()
            ))
        } else if pressure > 50 {
            advice.append(AIAdvice(
                type: .memory,
                title: "Memory under pressure",
                description: "Memory pressure at \(Int(pressure))%. The system is actively managing memory.",
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
                    title: "Heavy swap: \(String(format: "%.1f", swapGB)) GB",
                    description: "The system is using disk as memory. This significantly hurts performance.",
                    severity: .critical,
                    action: .openActivityMonitor,
                    timestamp: Date()
                ))
            } else if swapGB > 0.5 {
                advice.append(AIAdvice(
                    type: .memory,
                    title: "Swap in use",
                    description: "\(String(format: "%.1f", swapGB)) GB of swap active. Consider closing some apps.",
                    severity: .warning,
                    action: nil,
                    timestamp: Date()
                ))
            }
        }

        // Memory-leak detection (steady upward trend)
        if let trend = calculateTrend(memoryHistory, windowMinutes: 5), trend > 10 {
            advice.append(AIAdvice(
                type: .memory,
                title: "Possible memory leak",
                description: "Memory pressure has steadily increased by \(Int(trend))% over 5 minutes. An app may be leaking memory.",
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
                title: "Critical temperature: \(Int(temp))°C",
                description: "The Mac may thermally throttle. Reduce the workload or improve ventilation.",
                severity: .critical,
                action: nil,
                timestamp: Date()
            ))
        } else if temp > 85 {
            advice.append(AIAdvice(
                type: .temperature,
                title: "Elevated temperature: \(Int(temp))°C",
                description: "The CPU is warming up. Normal under heavy load.",
                severity: .warning,
                action: nil,
                timestamp: Date()
            ))
        }

        // High temperature with low CPU = problem
        if temp > 80 && cpuUsage < 30 {
            advice.append(AIAdvice(
                type: .temperature,
                title: "Anomalous temperature",
                description: "Temperature \(Int(temp))°C with CPU at \(Int(cpuUsage))%. Possible ventilation issue or hidden process.",
                severity: .warning,
                action: .openActivityMonitor,
                timestamp: Date()
            ))
        }

        // Temperature rising fast
        if let trend = calculateTrend(tempHistory, windowMinutes: 1), trend > 10 {
            advice.append(AIAdvice(
                type: .temperature,
                title: "Temperature rising rapidly",
                description: "Temperature rose by \(Int(trend))°C in the last minute.",
                severity: .info,
                action: nil,
                timestamp: Date()
            ))
        }

        return advice
    }

    private func analyzeProcesses(_ processes: [ProcessInfo]) -> [AIAdvice] {
        var advice: [AIAdvice] = []

        // Long-running processes burning CPU
        for process in processes {
            if process.cpuTimeMinutes > 60 && process.cpuPercent > 20 {
                advice.append(AIAdvice(
                    type: .process,
                    title: "\(process.name) long-running",
                    description: "Running at \(Int(process.cpuPercent))% CPU for \(Int(process.cpuTimeMinutes)) minutes. May be stuck.",
                    severity: process.cpuPercent > 50 ? .warning : .info,
                    action: .terminateProcess(pid: process.id, name: process.name),
                    timestamp: Date()
                ))
            }
        }

        // Too many high-CPU processes
        let highCPUProcesses = processes.filter { $0.cpuPercent > 30 }
        if highCPUProcesses.count > 3 {
            advice.append(AIAdvice(
                type: .process,
                title: "\(highCPUProcesses.count) high-CPU processes",
                description: "Multiple processes are competing for the CPU. Consider closing the ones you don't need.",
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

    /// Trend over a recent time window, in *raw value units* (not a
    /// percentage). For pressure series the unit is percentage points;
    /// for temperature it's °C. The advice thresholds above compare
    /// against this delta directly. Returns `nil` when there is no
    /// pair of samples to compare (history shorter than 2, or fewer
    /// than 2 samples fall inside the window).
    private func calculateTrend(_ history: [AIDataPoint], windowMinutes: Int) -> Double? {
        Self.trend(in: history, windowMinutes: windowMinutes, now: Date())
    }

    /// Pure variant of `calculateTrend`, with an explicit `now` so the
    /// windowing logic can be tested deterministically without
    /// touching the wall clock. `nonisolated` because it touches no
    /// actor-protected state — needed so tests (and any background
    /// caller) can invoke it without hopping to the main actor.
    nonisolated static func trend(in history: [AIDataPoint], windowMinutes: Int, now: Date) -> Double? {
        guard history.count >= 2 else { return nil }
        let windowStart = now.addingTimeInterval(-Double(windowMinutes * 60))
        let windowData = history.filter { $0.timestamp >= windowStart }
        guard windowData.count >= 2,
              let first = windowData.first,
              let last = windowData.last else { return nil }
        return last.value - first.value
    }
}
