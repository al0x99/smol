import Foundation
import NaturalLanguage

/// Processore di linguaggio naturale per query sul sistema
/// Usa NaturalLanguage framework di Apple per analisi semantica
class NaturalLanguageProcessor {

    // MARK: - Query Types

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

    /// Processa una query in linguaggio naturale e restituisce una risposta
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

    // MARK: - Intent Detection

    /// Rileva l'intento della query usando NaturalLanguage
    private func detectIntent(_ query: String) -> QueryIntent {
        let lowercased = query.lowercased()

        // Pattern matching per intenti comuni
        let cpuKeywords = ["cpu", "processore", "processor", "uso cpu", "utilizzo cpu"]
        let memoryKeywords = ["memoria", "ram", "memory", "swap"]
        let tempKeywords = ["temperatura", "caldo", "temperature", "hot", "thermal", "scald"]
        let slowKeywords = ["lento", "slow", "rallenta", "perché", "why", "cosa succede"]
        let closeKeywords = ["chiudere", "close", "terminare", "kill", "quale app"]
        let processKeywords = ["processo", "app", "programma", "process", "application"]
        let anomalyKeywords = ["anomalia", "problema", "issue", "anomaly", "strano", "weird"]

        // Rileva intento
        if cpuKeywords.contains(where: { lowercased.contains($0) }) {
            return .cpuStatus
        }
        if memoryKeywords.contains(where: { lowercased.contains($0) }) {
            return .memoryStatus
        }
        if tempKeywords.contains(where: { lowercased.contains($0) }) {
            return .temperatureStatus
        }
        if slowKeywords.contains(where: { lowercased.contains($0) }) {
            return .whySlow
        }
        if closeKeywords.contains(where: { lowercased.contains($0) }) {
            return .whatToClose
        }
        if anomalyKeywords.contains(where: { lowercased.contains($0) }) {
            return .anomalyInfo
        }
        if processKeywords.contains(where: { lowercased.contains($0) }) {
            // Estrai nome processo se presente
            let processName = extractProcessName(from: query)
            return .processInfo(name: processName)
        }

        // Usa NLP per analisi più avanzata
        return analyzeWithNLP(query)
    }

    /// Usa NaturalLanguage framework per analisi semantica
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

        // Se è una domanda generica sullo stato
        if hasQuestion || query.contains("come") || query.contains("how") {
            return .generalStatus
        }

        return .unknown
    }

    /// Estrae nome processo dalla query
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

        // Fallback: cerca parole che sembrano nomi di app (capitalizzate)
        if processName == nil {
            let words = query.split(separator: " ")
            for word in words {
                let str = String(word)
                if str.first?.isUppercase == true && str.count > 2 {
                    processName = str
                    break
                }
            }
        }

        return processName
    }

    // MARK: - Context Building

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

    // MARK: - Response Generation

    private func generateResponse(for intent: QueryIntent, context: QueryContext, query: String) -> String {
        switch intent {
        case .cpuStatus:
            return generateCPUResponse(context)

        case .memoryStatus:
            return generateMemoryResponse(context)

        case .temperatureStatus:
            return generateTemperatureResponse(context)

        case .whySlow:
            return generateWhySlowResponse(context)

        case .whatToClose:
            return generateWhatToCloseResponse(context)

        case .processInfo(let name):
            return generateProcessResponse(name: name, context: context)

        case .anomalyInfo:
            return generateAnomalyResponse(context)

        case .generalStatus:
            return generateGeneralResponse(context)

        case .unknown:
            return generateUnknownResponse(query)
        }
    }

    private func generateCPUResponse(_ context: QueryContext) -> String {
        let status: String
        if context.currentCPU > 80 {
            status = "molto alta"
        } else if context.currentCPU > 50 {
            status = "moderata"
        } else {
            status = "normale"
        }

        var response = "La CPU è al \(Int(context.currentCPU))% (\(status)). "
        response += "Media recente: \(Int(context.avgCPU))%. "

        if context.currentCPU > context.avgCPU + 20 {
            response += "L'uso è superiore alla media, qualche processo sta lavorando intensamente."
        } else if context.currentCPU < context.avgCPU - 10 {
            response += "L'uso è sotto la media, il sistema è tranquillo."
        }

        return response
    }

    private func generateMemoryResponse(_ context: QueryContext) -> String {
        let status: String
        if context.currentMemory > 80 {
            status = "critica"
        } else if context.currentMemory > 50 {
            status = "moderata"
        } else {
            status = "normale"
        }

        var response = "Memory pressure al \(Int(context.currentMemory))% (\(status)). "

        if context.currentMemory > 70 {
            response += "Considera chiudere alcune app per liberare memoria."
        } else {
            response += "Il sistema ha memoria sufficiente per le operazioni correnti."
        }

        return response
    }

    private func generateTemperatureResponse(_ context: QueryContext) -> String {
        let status: String
        if context.currentTemp > 90 {
            status = "critica"
        } else if context.currentTemp > 75 {
            status = "elevata"
        } else if context.currentTemp > 60 {
            status = "normale sotto carico"
        } else {
            status = "ottimale"
        }

        var response = "Temperatura CPU a \(Int(context.currentTemp))°C (\(status)). "

        if context.currentTemp > 85 {
            response += "Il Mac potrebbe throttlare per proteggersi. Riduci il carico."
        } else if context.currentTemp > 75 {
            response += "Normale per lavori intensivi, monitora se continua."
        }

        return response
    }

    private func generateWhySlowResponse(_ context: QueryContext) -> String {
        var reasons: [String] = []

        if context.currentCPU > 80 {
            reasons.append("CPU molto alta (\(Int(context.currentCPU))%)")
        }
        if context.currentMemory > 70 {
            reasons.append("memoria sotto pressione (\(Int(context.currentMemory))%)")
        }
        if context.currentTemp > 90 {
            reasons.append("thermal throttling (temperatura \(Int(context.currentTemp))°C)")
        }

        for advice in context.criticalAdvice {
            reasons.append(advice.title.lowercased())
        }

        if reasons.isEmpty {
            return "Il sistema sembra funzionare normalmente. Se è lento, potrebbe essere un problema specifico di un'app o del disco."
        }

        return "Il Mac potrebbe essere lento per: " + reasons.joined(separator: ", ") + ". " +
               "Consiglio: controlla Activity Monitor per dettagli."
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
                return "Non ho trovato processi problematici specifici, ma chiudere app non utilizzate potrebbe aiutare con la memoria."
            }
            return "Il sistema funziona bene, non serve chiudere nulla al momento."
        }

        return "Considera chiudere: " + suggestions.joined(separator: ", ") + ". " +
               "Questi processi stanno usando molte risorse."
    }

    private func generateProcessResponse(name: String?, context: QueryContext) -> String {
        if let name = name {
            // Per ora risposta generica, potrebbe essere esteso con lookup reale
            return "Per informazioni dettagliate su '\(name)', controlla la tab Processi o usa Activity Monitor."
        }
        return "Specifica il nome del processo per avere informazioni. Esempio: 'Come sta Chrome?'"
    }

    private func generateAnomalyResponse(_ context: QueryContext) -> String {
        if context.anomalies.isEmpty {
            return "Nessuna anomalia rilevata. Il sistema funziona normalmente."
        }

        var response = "Ho rilevato \(context.anomalies.count) anomalia/e:\n"
        for anomaly in context.anomalies {
            response += "• \(anomaly.type.rawValue): \(anomaly.description) (confidenza: \(Int(anomaly.confidence * 100))%)\n"
        }
        return response
    }

    private func generateGeneralResponse(_ context: QueryContext) -> String {
        var status = "Il sistema è "

        if context.hasIssues {
            status += "sotto stress. "
            if !context.criticalAdvice.isEmpty {
                status += "Ci sono \(context.criticalAdvice.count) problemi critici. "
            }
            if !context.warningAdvice.isEmpty {
                status += "\(context.warningAdvice.count) avvisi attivi. "
            }
        } else {
            status += "in buone condizioni. "
        }

        status += "CPU: \(Int(context.currentCPU))%, Memoria: \(Int(context.currentMemory))%, Temp: \(Int(context.currentTemp))°C."

        return status
    }

    private func generateUnknownResponse(_ query: String) -> String {
        return """
        Non ho capito bene la domanda. Prova a chiedere:
        • "Come sta la CPU?"
        • "Perché il Mac è lento?"
        • "Cosa dovrei chiudere?"
        • "Ci sono anomalie?"
        • "Qual è la temperatura?"
        """
    }
}
