import Foundation
import NaturalLanguage
import Combine

/// Engine per generazione testo intelligente
/// Usa embedding semantici e template avanzati per risposte contestuali
/// Preparato per integrazione MLX quando disponibile
/// Include tracking risorse per trasparenza all'utente
@MainActor
class LocalLLMEngine: ObservableObject {
    static let shared = LocalLLMEngine()

    // MARK: - Published State

    @Published var isInitialized = false
    @Published var isGenerating = false
    @Published var lastResponse: String?
    @Published var lastResourceCost: ResourceTracker.ResourceCost?
    @Published var showResourceWarning = false

    // MARK: - NL Components

    private let embedding: NLEmbedding?
    private let tagger: NLTagger
    private let recognizer: NLLanguageRecognizer

    // Context memory for conversation
    private var conversationContext: [ContextItem] = []
    private let maxContextItems = 10

    // MARK: - Initialization

    init() {
        // Carica embedding italiano/inglese per similarità semantica
        embedding = NLEmbedding.wordEmbedding(for: .italian) ?? NLEmbedding.wordEmbedding(for: .english)
        tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType, .sentimentScore])
        recognizer = NLLanguageRecognizer()

        isInitialized = embedding != nil

        // Carica contesto salvato
        loadContext()
    }

    // MARK: - Types

    struct ContextItem: Codable {
        let role: String // "user" o "assistant"
        let content: String
        let timestamp: Date
        let sentiment: Double?
        let topics: [String]
    }

    struct SystemContext {
        let cpuUsage: Double
        let memoryPressure: Double
        let temperature: Double
        let activeAdvice: [String]
        let anomalies: [String]
        let prediction: AnomalyPredictionInfo?
    }

    /// Info sulla predizione ML (disaccoppiato da MLAnomalyEngine)
    struct AnomalyPredictionInfo {
        let isAnomaly: Bool
        let confidence: Double
        let anomalyType: String?
        let predictedCPU: Double
        let predictedMemory: Double
        let predictedTemp: Double
    }

    // MARK: - Response Generation

    /// Risultato con risposta e costo risorse
    struct GenerationResult {
        let response: String
        let resourceCost: ResourceTracker.ResourceCost
        let costSummary: String
    }

    /// Stima il costo prima di generare (per UI di conferma)
    func estimateCost(query: String) -> ResourceTracker.CostEstimate {
        let wordCount = query.split(separator: " ").count
        let estimatedTokens = wordCount * 2  // Approssimazione
        return ResourceTracker.estimateLLMCost(inputTokens: estimatedTokens, modelSize: .tiny)
    }

    /// Genera una risposta intelligente alla query
    func generateResponse(
        query: String,
        systemContext: SystemContext
    ) async -> String {
        isGenerating = true
        defer { isGenerating = false }

        // Traccia risorse durante la generazione
        let tracker = ResourceTracker.shared
        tracker.startTracking()

        // 1. Analizza la query
        let analysis = analyzeQuery(query)

        // 2. Aggiungi al contesto
        addToContext(role: "user", content: query, sentiment: analysis.sentiment, topics: analysis.topics)

        // 3. Genera risposta basata sull'analisi
        let response = await buildResponse(
            query: query,
            analysis: analysis,
            systemContext: systemContext
        )

        // Conta token approssimati
        let outputTokens = response.split(separator: " ").count
        tracker.addTokens(outputTokens)

        // 4. Aggiungi risposta al contesto
        addToContext(role: "assistant", content: response, sentiment: nil, topics: analysis.topics)

        // 5. Ferma tracking e salva costo
        let cost = tracker.stopTracking()
        lastResourceCost = cost

        lastResponse = response
        return response
    }

    /// Genera risposta con report dettagliato delle risorse
    func generateResponseWithCost(
        query: String,
        systemContext: SystemContext
    ) async -> GenerationResult {
        let response = await generateResponse(query: query, systemContext: systemContext)
        let cost = lastResourceCost ?? ResourceTracker.ResourceCost(
            duration: 0, avgCPU: 0, peakCPU: 0, memoryDelta: 0,
            peakMemory: 0, estimatedEnergy: 0, tokenCount: nil
        )

        return GenerationResult(
            response: response,
            resourceCost: cost,
            costSummary: cost.userFriendlyDescription
        )
    }

    // MARK: - Query Analysis

    struct QueryAnalysis {
        let intent: QueryIntent
        let sentiment: Double // -1 a 1
        let topics: [String]
        let entities: [String: String] // nome -> tipo
        let urgency: Double // 0 a 1
        let isQuestion: Bool
    }

    enum QueryIntent: String {
        case statusCheck = "status"
        case troubleshoot = "troubleshoot"
        case optimize = "optimize"
        case explain = "explain"
        case predict = "predict"
        case compare = "compare"
        case action = "action"
        case chitchat = "chitchat"
    }

    private func analyzeQuery(_ query: String) -> QueryAnalysis {
        let lowercased = query.lowercased()

        // Sentiment analysis
        tagger.string = query
        var sentimentSum = 0.0
        var count = 0

        tagger.enumerateTags(in: query.startIndex..<query.endIndex, unit: .paragraph, scheme: .sentimentScore) { tag, _ in
            if let tag = tag, let score = Double(tag.rawValue) {
                sentimentSum += score
                count += 1
            }
            return true
        }
        let sentiment = count > 0 ? sentimentSum / Double(count) : 0

        // Topic extraction
        var topics: [String] = []
        var entities: [String: String] = [:]

        tagger.enumerateTags(in: query.startIndex..<query.endIndex, unit: .word, scheme: .lexicalClass) { tag, range in
            if tag == .noun {
                topics.append(String(query[range]))
            }
            return true
        }

        // Named entities
        tagger.enumerateTags(in: query.startIndex..<query.endIndex, unit: .word, scheme: .nameType) { tag, range in
            if let tag = tag {
                entities[String(query[range])] = tag.rawValue
            }
            return true
        }

        // Intent detection con keyword matching + semantic similarity
        let intent = detectIntent(lowercased)

        // Urgency detection
        let urgencyKeywords = ["urgente", "subito", "immediato", "critico", "emergency", "urgent", "now", "help"]
        let urgency = urgencyKeywords.contains(where: { lowercased.contains($0) }) ? 0.9 : 0.3

        // Is question
        let isQuestion = query.contains("?") || lowercased.starts(with: "come") ||
                         lowercased.starts(with: "perché") || lowercased.starts(with: "cosa") ||
                         lowercased.starts(with: "quanto") || lowercased.starts(with: "qual")

        return QueryAnalysis(
            intent: intent,
            sentiment: sentiment,
            topics: topics,
            entities: entities,
            urgency: urgency,
            isQuestion: isQuestion
        )
    }

    private func detectIntent(_ query: String) -> QueryIntent {
        // Keywords per ogni intent
        let intentKeywords: [QueryIntent: [String]] = [
            .statusCheck: ["come sta", "status", "stato", "situazione", "salute", "quanto", "attuale"],
            .troubleshoot: ["problema", "errore", "lento", "bug", "crash", "perché", "non funziona", "aiuto"],
            .optimize: ["ottimizza", "migliora", "velocizza", "libera", "pulisci", "performance"],
            .explain: ["spiega", "cos'è", "cosa significa", "perché", "come funziona"],
            .predict: ["prevedi", "previsione", "futuro", "trend", "andrà"],
            .compare: ["confronta", "differenza", "meglio", "peggio", "vs"],
            .action: ["chiudi", "termina", "avvia", "apri", "esegui", "fai"]
        ]

        for (intent, keywords) in intentKeywords {
            if keywords.contains(where: { query.contains($0) }) {
                return intent
            }
        }

        // Usa embedding per similarità se disponibile
        if let embedding = embedding {
            let queryWords = query.split(separator: " ").map(String.init)
            var bestIntent = QueryIntent.chitchat
            var bestScore = 0.0

            for (intent, keywords) in intentKeywords {
                var score = 0.0
                for word in queryWords {
                    for keyword in keywords {
                        // NLEmbedding.distance restituisce Double (non Optional)
                        // Ritorna un valore molto alto se le parole non sono nel vocabolario
                        let distance = embedding.distance(between: word, and: keyword)
                        if distance < 2.0 { // Solo se le parole sono nel vocabolario
                            score += max(0, 1 - distance) // Converti distanza in similarità
                        }
                    }
                }
                if score > bestScore {
                    bestScore = score
                    bestIntent = intent
                }
            }

            if bestScore > 0.5 {
                return bestIntent
            }
        }

        return .chitchat
    }

    // MARK: - Response Building

    private func buildResponse(
        query: String,
        analysis: QueryAnalysis,
        systemContext: SystemContext
    ) async -> String {

        // Costruisci risposta basata sull'intent
        switch analysis.intent {
        case .statusCheck:
            return buildStatusResponse(systemContext: systemContext, topics: analysis.topics)

        case .troubleshoot:
            return buildTroubleshootResponse(systemContext: systemContext, query: query)

        case .optimize:
            return buildOptimizeResponse(systemContext: systemContext)

        case .explain:
            return buildExplainResponse(query: query, systemContext: systemContext)

        case .predict:
            return buildPredictResponse(systemContext: systemContext)

        case .compare:
            return buildCompareResponse(query: query, systemContext: systemContext)

        case .action:
            return buildActionResponse(query: query, systemContext: systemContext)

        case .chitchat:
            return buildChitchatResponse(query: query, sentiment: analysis.sentiment)
        }
    }

    // MARK: - Response Templates

    private func buildStatusResponse(systemContext: SystemContext, topics: [String]) -> String {
        let cpu = systemContext.cpuUsage
        let mem = systemContext.memoryPressure
        let temp = systemContext.temperature

        // Determina focus basato sui topics
        let focusCPU = topics.contains(where: { $0.lowercased().contains("cpu") || $0.lowercased().contains("processore") })
        let focusMemory = topics.contains(where: { $0.lowercased().contains("memoria") || $0.lowercased().contains("ram") })
        let focusTemp = topics.contains(where: { $0.lowercased().contains("temperatura") || $0.lowercased().contains("caldo") })

        var parts: [String] = []

        // Valutazione generale
        let healthScore = calculateHealthScore(cpu: cpu, memory: mem, temp: temp)
        let healthEmoji = healthScore > 80 ? "✅" : (healthScore > 50 ? "⚠️" : "🔴")

        if !focusCPU && !focusMemory && !focusTemp {
            // Risposta generale
            parts.append("\(healthEmoji) **Stato generale: \(healthDescriptor(healthScore))**")
            parts.append("")
        }

        if !focusMemory && !focusTemp || focusCPU {
            let cpuStatus = cpu > 80 ? "elevato" : (cpu > 50 ? "moderato" : "normale")
            parts.append("• **CPU**: \(Int(cpu))% (\(cpuStatus))")
        }

        if !focusCPU && !focusTemp || focusMemory {
            let memStatus = mem > 70 ? "sotto pressione" : (mem > 40 ? "moderata" : "ok")
            parts.append("• **Memoria**: \(Int(mem))% (\(memStatus))")
        }

        if !focusCPU && !focusMemory || focusTemp {
            let tempStatus = temp > 85 ? "alta" : (temp > 65 ? "normale" : "bassa")
            parts.append("• **Temperatura**: \(Int(temp))°C (\(tempStatus))")
        }

        // Aggiungi prediction ML se disponibile
        if let prediction = systemContext.prediction {
            if prediction.isAnomaly {
                parts.append("")
                parts.append("🤖 **ML Detection**: Anomalia rilevata (\(prediction.anomalyType ?? "sconosciuta")) con confidenza \(Int(prediction.confidence * 100))%")
            }
        }

        // Aggiungi consigli se presenti
        if !systemContext.activeAdvice.isEmpty {
            parts.append("")
            parts.append("**Suggerimenti attivi:**")
            for advice in systemContext.activeAdvice.prefix(3) {
                parts.append("• \(advice)")
            }
        }

        return parts.joined(separator: "\n")
    }

    private func buildTroubleshootResponse(systemContext: SystemContext, query: String) -> String {
        var issues: [String] = []
        var solutions: [String] = []

        let cpu = systemContext.cpuUsage
        let mem = systemContext.memoryPressure
        let temp = systemContext.temperature

        if cpu > 80 {
            issues.append("CPU al \(Int(cpu))%")
            solutions.append("Chiudi le app che non usi o controlla Activity Monitor per processi anomali")
        }

        if mem > 70 {
            issues.append("Memoria sotto pressione (\(Int(mem))%)")
            solutions.append("Chiudi tab del browser non necessarie o riavvia app pesanti")
        }

        if temp > 85 {
            issues.append("Temperatura elevata (\(Int(temp))°C)")
            solutions.append("Migliora la ventilazione o riduci il carico di lavoro")
        }

        if !systemContext.anomalies.isEmpty {
            issues.append(contentsOf: systemContext.anomalies)
        }

        if issues.isEmpty {
            return """
            🔍 **Diagnostica completata**

            Non ho trovato problemi evidenti. Il sistema sembra funzionare normalmente.

            Se riscontri lentezza, potrebbe essere dovuto a:
            • Un'app specifica (controlla Activity Monitor)
            • Disco pieno o frammentato
            • Problemi di rete
            """
        }

        var response = "🔧 **Problemi rilevati:**\n\n"
        for issue in issues {
            response += "• \(issue)\n"
        }

        response += "\n**Soluzioni suggerite:**\n\n"
        for (i, solution) in solutions.enumerated() {
            response += "\(i + 1). \(solution)\n"
        }

        return response
    }

    private func buildOptimizeResponse(systemContext: SystemContext) -> String {
        var suggestions: [String] = []

        if systemContext.memoryPressure > 50 {
            suggestions.append("**Libera memoria**: Chiudi app in background inutilizzate")
        }

        if systemContext.cpuUsage > 40 {
            suggestions.append("**Riduci carico CPU**: Identifica processi pesanti in Activity Monitor")
        }

        if systemContext.temperature > 70 {
            suggestions.append("**Raffredda il Mac**: Migliora ventilazione o usa una base di raffreddamento")
        }

        suggestions.append("**Manutenzione**: Riavvia il Mac periodicamente per liberare risorse")
        suggestions.append("**Storage**: Mantieni almeno 20GB liberi sul disco")

        return """
        ⚡ **Suggerimenti per ottimizzare:**

        \(suggestions.map { "• \($0)" }.joined(separator: "\n"))

        💡 **Tip**: L'ottimizzazione migliore è spesso chiudere ciò che non serve!
        """
    }

    private func buildExplainResponse(query: String, systemContext: SystemContext) -> String {
        let lowercased = query.lowercased()

        if lowercased.contains("cpu") {
            return """
            📚 **CPU (Central Processing Unit)**

            La CPU è il "cervello" del Mac. L'utilizzo indica quanto sta lavorando.

            • **0-30%**: Idle, normale per uso leggero
            • **30-60%**: Uso moderato (navigazione, documenti)
            • **60-80%**: Carico pesante (video editing, compilazione)
            • **80-100%**: Massimo carico, possibile rallentamento

            Attualmente: **\(Int(systemContext.cpuUsage))%**
            """
        }

        if lowercased.contains("memoria") || lowercased.contains("ram") || lowercased.contains("pressure") {
            return """
            📚 **Memory Pressure**

            Indica quanto il sistema sta "faticando" a gestire la memoria.

            • **Verde (0-50%)**: Memoria abbondante
            • **Giallo (50-80%)**: Compressione attiva, normale
            • **Rosso (80-100%)**: Swap su disco, rallentamento

            Attualmente: **\(Int(systemContext.memoryPressure))%**

            macOS usa la memoria in modo intelligente: la "memoria usata" alta non è un problema finché la pressure è bassa.
            """
        }

        if lowercased.contains("temperatura") || lowercased.contains("temp") {
            return """
            📚 **Temperatura CPU**

            Apple Silicon è progettato per funzionare fino a ~100°C con throttling.

            • **< 50°C**: Idle o carico leggero
            • **50-75°C**: Uso normale
            • **75-95°C**: Carico pesante, normale
            • **> 95°C**: Thermal throttling attivo

            Attualmente: **\(Int(systemContext.temperature))°C**

            I Mac senza ventola (Air) raggiungono temperature più alte.
            """
        }

        return """
        🤔 Non sono sicuro di cosa vuoi che ti spieghi.

        Posso spiegarti:
        • **CPU** e utilizzo processore
        • **Memoria** e memory pressure
        • **Temperatura** e thermal throttling

        Prova: "Spiega cosa significa memory pressure"
        """
    }

    private func buildPredictResponse(systemContext: SystemContext) -> String {
        guard let prediction = systemContext.prediction else {
            return """
            🔮 **Previsione non disponibile**

            Il modello ML non è ancora stato addestrato con i tuoi dati.

            Continua a usare smol per raccogliere dati e poi potrai:
            1. Addestrare il modello nel tab AI → Insights
            2. Ottenere previsioni personalizzate sul tuo Mac
            """
        }

        return """
        🔮 **Previsione ML**

        Basandomi sui pattern appresi dal tuo utilizzo:

        • **CPU prevista**: ~\(Int(prediction.predictedCPU))%
        • **Memoria prevista**: ~\(Int(prediction.predictedMemory))%
        • **Temperatura prevista**: ~\(Int(prediction.predictedTemp))°C

        **Stato**: \(prediction.isAnomaly ? "⚠️ Anomalia rilevata" : "✅ Comportamento normale")
        **Confidenza**: \(Int(prediction.confidence * 100))%

        \(prediction.isAnomaly && prediction.anomalyType != nil ? "Tipo: \(prediction.anomalyType!)" : "")
        """
    }

    private func buildCompareResponse(query: String, systemContext: SystemContext) -> String {
        return """
        📊 **Confronto attuale**

        | Metrica | Attuale | Tipico | Stato |
        |---------|---------|--------|-------|
        | CPU | \(Int(systemContext.cpuUsage))% | 20-40% | \(systemContext.cpuUsage > 50 ? "⬆️" : "✅") |
        | Memoria | \(Int(systemContext.memoryPressure))% | 30-50% | \(systemContext.memoryPressure > 60 ? "⬆️" : "✅") |
        | Temp | \(Int(systemContext.temperature))°C | 45-65°C | \(systemContext.temperature > 75 ? "⬆️" : "✅") |

        Per confronti più dettagliati, specifica cosa vuoi confrontare!
        """
    }

    private func buildActionResponse(query: String, systemContext: SystemContext) -> String {
        let lowercased = query.lowercased()

        if lowercased.contains("activity monitor") || lowercased.contains("monitoraggio attività") {
            return """
            📱 **Apertura Activity Monitor**

            Puoi aprirlo in diversi modi:
            1. **Spotlight**: Cmd+Spazio → "Activity Monitor"
            2. **Finder**: Applicazioni → Utility → Monitoraggio Attività
            3. **Tramite smol**: Clicca l'azione nei consigli

            Vuoi che lo apra per te?
            """
        }

        return """
        🎬 **Azioni disponibili**

        Posso aiutarti con:
        • Aprire Activity Monitor
        • Mostrarti processi che usano molte risorse
        • Generare un report del sistema

        Cosa vuoi fare?
        """
    }

    private func buildChitchatResponse(query: String, sentiment: Double) -> String {
        if sentiment < -0.3 {
            return """
            Mi dispiace che tu stia avendo problemi! 😟

            Dimmi di più su cosa sta succedendo e cercherò di aiutarti.

            Prova a chiedermi:
            • "Perché il Mac è lento?"
            • "Come sta il sistema?"
            • "Cosa dovrei ottimizzare?"
            """
        }

        return """
        Ciao! 👋 Sono l'assistente AI di smol.

        Posso aiutarti con:
        • 📊 **Stato sistema**: "Come sta il Mac?"
        • 🔧 **Problemi**: "Perché è lento?"
        • ⚡ **Ottimizzazione**: "Come posso velocizzare?"
        • 📚 **Spiegazioni**: "Cos'è la memory pressure?"
        • 🔮 **Previsioni**: "Prevedi problemi?"

        Cosa vuoi sapere?
        """
    }

    // MARK: - Helpers

    private func calculateHealthScore(cpu: Double, memory: Double, temp: Double) -> Int {
        var score = 100

        if cpu > 80 { score -= 25 }
        else if cpu > 50 { score -= 10 }

        if memory > 80 { score -= 25 }
        else if memory > 50 { score -= 10 }

        if temp > 90 { score -= 25 }
        else if temp > 75 { score -= 10 }

        return max(0, score)
    }

    private func healthDescriptor(_ score: Int) -> String {
        switch score {
        case 90...100: return "Eccellente"
        case 70..<90: return "Buono"
        case 50..<70: return "Moderato"
        case 30..<50: return "Problematico"
        default: return "Critico"
        }
    }

    // MARK: - Context Management

    private func addToContext(role: String, content: String, sentiment: Double?, topics: [String]) {
        let item = ContextItem(
            role: role,
            content: content,
            timestamp: Date(),
            sentiment: sentiment,
            topics: topics
        )

        conversationContext.append(item)

        // Mantieni solo gli ultimi N items
        if conversationContext.count > maxContextItems {
            conversationContext.removeFirst(conversationContext.count - maxContextItems)
        }

        saveContext()
    }

    private func saveContext() {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("smol/conversation_context.json")

        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        if let data = try? JSONEncoder().encode(conversationContext) {
            try? data.write(to: url)
        }
    }

    private func loadContext() {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("smol/conversation_context.json")

        if let data = try? Data(contentsOf: url),
           let context = try? JSONDecoder().decode([ContextItem].self, from: data) {
            conversationContext = context
        }
    }

    func clearContext() {
        conversationContext = []
        saveContext()
    }
}
