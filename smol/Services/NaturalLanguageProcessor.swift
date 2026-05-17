import Foundation
import NaturalLanguage

/// Natural-language processor for system queries.
/// Uses Apple's NaturalLanguage framework for intent detection and falls back
/// to keyword matching. Responses are English-only; the keyword sets accept
/// both English and Italian terms so existing users can keep their phrasing.
class NaturalLanguageProcessor {

    // MARK: - Query types

    enum QueryIntent {
        case cpuStatus
        case memoryStatus
        case temperatureStatus
        case processInfo(name: String?)
        case whySlow
        case whatToClose
        case generalStatus
        case anomalyInfo
        case unknown
    }

    // MARK: - Public API

    func processQuery(
        _ query: String,
        cpuHistory: [AIDataPoint],
        memoryHistory: [AIDataPoint],
        tempHistory: [AIDataPoint],
        currentAdvice: [AIAdvice],
        anomalies: [AIAnomaly]
    ) -> String {
        let intent = detectIntent(query)
        let context = buildContext(
            cpuHistory: cpuHistory,
            memoryHistory: memoryHistory,
            tempHistory: tempHistory,
            advice: currentAdvice,
            anomalies: anomalies
        )
        return generateResponse(for: intent, context: context, query: query)
    }

    // MARK: - Intent detection

    private func detectIntent(_ query: String) -> QueryIntent {
        let lowercased = query.lowercased()

        // Bilingual keywords so EN/IT phrasing both match.
        let cpuKeywords     = ["cpu", "processor", "processore", "uso cpu", "utilizzo cpu"]
        let memoryKeywords  = ["memory", "ram", "swap", "memoria"]
        let tempKeywords    = ["temperature", "hot", "thermal", "temperatura", "caldo", "scald"]
        let slowKeywords    = ["slow", "why", "lento", "rallenta", "perché", "cosa succede"]
        let closeKeywords   = ["close", "kill", "which app", "chiudere", "terminare", "quale app"]
        let processKeywords = ["process", "app", "application", "programma", "processo"]
        let anomalyKeywords = ["anomaly", "issue", "weird", "anomalia", "problema", "strano"]

        if cpuKeywords.contains(where: { lowercased.contains($0) })     { return .cpuStatus }
        if memoryKeywords.contains(where: { lowercased.contains($0) })  { return .memoryStatus }
        if tempKeywords.contains(where: { lowercased.contains($0) })    { return .temperatureStatus }
        if slowKeywords.contains(where: { lowercased.contains($0) })    { return .whySlow }
        if closeKeywords.contains(where: { lowercased.contains($0) })   { return .whatToClose }
        if anomalyKeywords.contains(where: { lowercased.contains($0) }) { return .anomalyInfo }
        if processKeywords.contains(where: { lowercased.contains($0) }) {
            return .processInfo(name: extractProcessName(from: query))
        }

        return analyzeWithNLP(query)
    }

    /// Uses NaturalLanguage framework for a lighter semantic pass.
    private func analyzeWithNLP(_ query: String) -> QueryIntent {
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType])
        tagger.string = query

        var hasQuestion = false
        var topics: [String] = []

        tagger.enumerateTags(in: query.startIndex..<query.endIndex, unit: .word, scheme: .lexicalClass) { tag, range in
            if let tag = tag {
                let word = String(query[range]).lowercased()
                switch tag {
                case .noun:
                    topics.append(word)
                case .particle where word.contains("?"):
                    hasQuestion = true
                default:
                    break
                }
            }
            return true
        }

        if hasQuestion || query.contains("how") || query.contains("come") {
            return .generalStatus
        }
        return .unknown
    }

    /// Pulls a likely process/app name out of the query.
    private func extractProcessName(from query: String) -> String? {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = query

        var processName: String?

        tagger.enumerateTags(in: query.startIndex..<query.endIndex, unit: .word, scheme: .nameType) { tag, range in
            if tag == .organizationName || tag == .personalName {
                processName = String(query[range])
            }
            return true
        }

        // Fallback: a capitalized word longer than two characters.
        if processName == nil {
            for word in query.split(separator: " ") {
                let str = String(word)
                if str.first?.isUppercase == true && str.count > 2 {
                    processName = str
                    break
                }
            }
        }

        return processName
    }

    // MARK: - Context

    struct QueryContext {
        let currentCPU: Double
        let avgCPU: Double
        let currentMemory: Double
        let avgMemory: Double
        let currentTemp: Double
        let avgTemp: Double
        let criticalAdvice: [AIAdvice]
        let warningAdvice: [AIAdvice]
        let anomalies: [AIAnomaly]
        let hasIssues: Bool
    }

    private func buildContext(
        cpuHistory: [AIDataPoint],
        memoryHistory: [AIDataPoint],
        tempHistory: [AIDataPoint],
        advice: [AIAdvice],
        anomalies: [AIAnomaly]
    ) -> QueryContext {
        let currentCPU = cpuHistory.last?.value ?? 0
        let avgCPU = cpuHistory.isEmpty ? 0 : cpuHistory.map { $0.value }.reduce(0, +) / Double(cpuHistory.count)

        let currentMemory = memoryHistory.last?.value ?? 0
        let avgMemory = memoryHistory.isEmpty ? 0 : memoryHistory.map { $0.value }.reduce(0, +) / Double(memoryHistory.count)

        let currentTemp = tempHistory.last?.value ?? 0
        let avgTemp = tempHistory.isEmpty ? 0 : tempHistory.map { $0.value }.reduce(0, +) / Double(tempHistory.count)

        let criticalAdvice = advice.filter { $0.severity == .critical }
        let warningAdvice = advice.filter { $0.severity == .warning }

        return QueryContext(
            currentCPU: currentCPU,
            avgCPU: avgCPU,
            currentMemory: currentMemory,
            avgMemory: avgMemory,
            currentTemp: currentTemp,
            avgTemp: avgTemp,
            criticalAdvice: criticalAdvice,
            warningAdvice: warningAdvice,
            anomalies: anomalies,
            hasIssues: !criticalAdvice.isEmpty || !warningAdvice.isEmpty || !anomalies.isEmpty
        )
    }

    // MARK: - Responses

    private func generateResponse(for intent: QueryIntent, context: QueryContext, query: String) -> String {
        switch intent {
        case .cpuStatus:         return generateCPUResponse(context)
        case .memoryStatus:      return generateMemoryResponse(context)
        case .temperatureStatus: return generateTemperatureResponse(context)
        case .whySlow:           return generateWhySlowResponse(context)
        case .whatToClose:       return generateWhatToCloseResponse(context)
        case .processInfo(let name): return generateProcessResponse(name: name, context: context)
        case .anomalyInfo:       return generateAnomalyResponse(context)
        case .generalStatus:     return generateGeneralResponse(context)
        case .unknown:           return generateUnknownResponse(query)
        }
    }

    private func generateCPUResponse(_ context: QueryContext) -> String {
        let status: String
        if context.currentCPU > 80 { status = "very high" }
        else if context.currentCPU > 50 { status = "moderate" }
        else { status = "normal" }

        var response = "CPU at \(Int(context.currentCPU))% (\(status)). "
        response += "Recent average: \(Int(context.avgCPU))%. "

        if context.currentCPU > context.avgCPU + 20 {
            response += "Usage is above average — some process is working hard."
        } else if context.currentCPU < context.avgCPU - 10 {
            response += "Usage is below average — the system is quiet."
        }
        return response
    }

    private func generateMemoryResponse(_ context: QueryContext) -> String {
        let status: String
        if context.currentMemory > 80 { status = "critical" }
        else if context.currentMemory > 50 { status = "moderate" }
        else { status = "normal" }

        var response = "Memory pressure at \(Int(context.currentMemory))% (\(status)). "

        if context.currentMemory > 70 {
            response += "Consider closing some apps to free up memory."
        } else {
            response += "The system has enough memory for what it's doing right now."
        }
        return response
    }

    private func generateTemperatureResponse(_ context: QueryContext) -> String {
        let status: String
        if context.currentTemp > 90 { status = "critical" }
        else if context.currentTemp > 75 { status = "elevated" }
        else if context.currentTemp > 60 { status = "normal under load" }
        else { status = "optimal" }

        var response = "CPU temperature at \(Int(context.currentTemp))°C (\(status)). "

        if context.currentTemp > 85 {
            response += "The Mac may throttle to protect itself. Reduce the workload."
        } else if context.currentTemp > 75 {
            response += "Normal for heavy work — keep an eye on it if it continues."
        }
        return response
    }

    private func generateWhySlowResponse(_ context: QueryContext) -> String {
        var reasons: [String] = []

        if context.currentCPU > 80 {
            reasons.append("CPU very high (\(Int(context.currentCPU))%)")
        }
        if context.currentMemory > 70 {
            reasons.append("memory under pressure (\(Int(context.currentMemory))%)")
        }
        if context.currentTemp > 90 {
            reasons.append("thermal throttling (temperature \(Int(context.currentTemp))°C)")
        }

        for advice in context.criticalAdvice {
            reasons.append(advice.title.lowercased())
        }

        if reasons.isEmpty {
            return "The system seems to be running normally. If it feels slow, it may be a specific app or a disk issue."
        }

        return "The Mac may be slow because of: " + reasons.joined(separator: ", ") + ". " +
               "Tip: open Activity Monitor for details."
    }

    private func generateWhatToCloseResponse(_ context: QueryContext) -> String {
        var suggestions: [String] = []

        for advice in context.criticalAdvice + context.warningAdvice {
            if case .terminateProcess(_, let name) = advice.action {
                suggestions.append(name)
            }
        }

        if suggestions.isEmpty {
            if context.currentMemory > 60 {
                return "I didn't find any specific problem processes, but closing apps you aren't using would help with memory."
            }
            return "The system is doing fine — nothing needs closing right now."
        }

        return "Consider closing: " + suggestions.joined(separator: ", ") + ". " +
               "These processes are using a lot of resources."
    }

    private func generateProcessResponse(name: String?, context: QueryContext) -> String {
        if let name = name {
            return "For more on '\(name)', check the Processes tab or use Activity Monitor."
        }
        return "Tell me the process name and I'll dig deeper. Example: \"How is Chrome doing?\""
    }

    private func generateAnomalyResponse(_ context: QueryContext) -> String {
        if context.anomalies.isEmpty {
            return "No anomalies detected. The system is behaving normally."
        }

        let noun = context.anomalies.count == 1 ? "anomaly" : "anomalies"
        var response = "I detected \(context.anomalies.count) \(noun):\n"
        for anomaly in context.anomalies {
            response += "• \(anomaly.type.rawValue): \(anomaly.description) (confidence: \(Int(anomaly.confidence * 100))%)\n"
        }
        return response
    }

    private func generateGeneralResponse(_ context: QueryContext) -> String {
        var status = "The system is "

        if context.hasIssues {
            status += "under stress. "
            if !context.criticalAdvice.isEmpty {
                let noun = context.criticalAdvice.count == 1 ? "critical issue" : "critical issues"
                status += "There are \(context.criticalAdvice.count) \(noun). "
            }
            if !context.warningAdvice.isEmpty {
                let noun = context.warningAdvice.count == 1 ? "active warning" : "active warnings"
                status += "\(context.warningAdvice.count) \(noun). "
            }
        } else {
            status += "in good shape. "
        }

        status += "CPU: \(Int(context.currentCPU))%, Memory: \(Int(context.currentMemory))%, Temp: \(Int(context.currentTemp))°C."
        return status
    }

    private func generateUnknownResponse(_ query: String) -> String {
        return """
        I didn't quite catch that. Try asking:
        • "How is the CPU?"
        • "Why is the Mac slow?"
        • "What should I close?"
        • "Are there any anomalies?"
        • "What's the temperature?"
        """
    }
}
