import Foundation
import NaturalLanguage
import Combine

/// Template-based text-generation engine (fallback).
/// Uses semantic embeddings and pattern-matched templates for contextual
/// answers when no real LLM backend (Apple AI / MLX / Cloud) is available.
/// Includes resource tracking so the user can see what each call costs.
@MainActor
class LocalLLMEngine: ObservableObject {
    static let shared = LocalLLMEngine()

    // MARK: - Published state

    @Published var isInitialized = false
    @Published var isGenerating = false
    @Published var lastResponse: String?
    @Published var lastResourceCost: ResourceTracker.ResourceCost?
    @Published var showResourceWarning = false

    // MARK: - NL components

    private let embedding: NLEmbedding?
    private let tagger: NLTagger
    private let recognizer: NLLanguageRecognizer

    // Conversation memory.
    private var conversationContext: [ContextItem] = []
    private let maxContextItems = 10

    // MARK: - Initialization

    init() {
        // English embedding by default; fall back to Italian if English isn't installed.
        embedding = NLEmbedding.wordEmbedding(for: .english) ?? NLEmbedding.wordEmbedding(for: .italian)
        tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType, .sentimentScore])
        recognizer = NLLanguageRecognizer()

        isInitialized = embedding != nil
        loadContext()
    }

    // MARK: - Types

    struct ContextItem: Codable {
        let role: String // "user" or "assistant"
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

    /// ML prediction info (decoupled from MLAnomalyEngine).
    struct AnomalyPredictionInfo {
        let isAnomaly: Bool
        let confidence: Double
        let anomalyType: String?
        let predictedCPU: Double
        let predictedMemory: Double
        let predictedTemp: Double
    }

    // MARK: - Response generation

    struct GenerationResult {
        let response: String
        let resourceCost: ResourceTracker.ResourceCost
        let costSummary: String
    }

    /// Estimate cost before generating (for confirmation UI).
    func estimateCost(query: String) -> ResourceTracker.CostEstimate {
        let wordCount = query.split(separator: " ").count
        let estimatedTokens = wordCount * 2
        return ResourceTracker.estimateLLMCost(inputTokens: estimatedTokens, modelSize: .tiny)
    }

    /// Generate an answer to the query.
    func generateResponse(
        query: String,
        systemContext: SystemContext
    ) async -> String {
        isGenerating = true
        defer { isGenerating = false }

        let tracker = ResourceTracker.shared
        tracker.startTracking()

        let analysis = analyzeQuery(query)
        addToContext(role: "user", content: query, sentiment: analysis.sentiment, topics: analysis.topics)

        let response = await buildResponse(
            query: query,
            analysis: analysis,
            systemContext: systemContext
        )

        let outputTokens = response.split(separator: " ").count
        tracker.addTokens(outputTokens)

        addToContext(role: "assistant", content: response, sentiment: nil, topics: analysis.topics)

        let cost = tracker.stopTracking()
        lastResourceCost = cost
        lastResponse = response
        return response
    }

    /// Generate with a detailed cost report.
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

    // MARK: - Query analysis

    struct QueryAnalysis {
        let intent: QueryIntent
        let sentiment: Double           // -1...1
        let topics: [String]
        let entities: [String: String]  // name -> type
        let urgency: Double             // 0...1
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

        // Sentiment.
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

        // Topics + entities.
        var topics: [String] = []
        var entities: [String: String] = [:]

        tagger.enumerateTags(in: query.startIndex..<query.endIndex, unit: .word, scheme: .lexicalClass) { tag, range in
            if tag == .noun {
                topics.append(String(query[range]))
            }
            return true
        }

        tagger.enumerateTags(in: query.startIndex..<query.endIndex, unit: .word, scheme: .nameType) { tag, range in
            if let tag = tag {
                entities[String(query[range])] = tag.rawValue
            }
            return true
        }

        let intent = detectIntent(lowercased)

        // Urgency cues (bilingual).
        let urgencyKeywords = ["urgent", "now", "help", "emergency", "critical",
                               "urgente", "subito", "immediato", "critico"]
        let urgency = urgencyKeywords.contains(where: { lowercased.contains($0) }) ? 0.9 : 0.3

        let isQuestion = query.contains("?")
            || lowercased.starts(with: "how")  || lowercased.starts(with: "why")
            || lowercased.starts(with: "what") || lowercased.starts(with: "when")
            || lowercased.starts(with: "come") || lowercased.starts(with: "perché")
            || lowercased.starts(with: "cosa") || lowercased.starts(with: "quanto")
            || lowercased.starts(with: "qual")

        return QueryAnalysis(
            intent: intent,
            sentiment: sentiment,
            topics: topics,
            entities: entities,
            urgency: urgency,
            isQuestion: isQuestion
        )
    }

    // Intent keyword table — order encodes priority. Previously this
    // was a `[QueryIntent: [String]]` and Swift's hash-seed randomization
    // meant a query matching multiple intents could return different
    // results across runs of the same process. The ordered tuple array
    // pins iteration order: first match wins.
    nonisolated static let intentKeywords: [(intent: QueryIntent, keywords: [String])] = [
        (.statusCheck,  ["status", "how is", "current", "health",
                         "stato", "come sta", "situazione", "salute", "quanto", "attuale"]),
        (.troubleshoot, ["problem", "issue", "slow", "bug", "crash", "why", "doesn't work", "help",
                         "problema", "errore", "lento", "perché", "non funziona", "aiuto"]),
        (.optimize,     ["optimize", "speed up", "improve", "clean", "performance",
                         "ottimizza", "migliora", "velocizza", "libera", "pulisci"]),
        (.explain,      ["explain", "what is", "what does", "how does",
                         "spiega", "cos'è", "cosa significa", "come funziona"]),
        (.predict,      ["predict", "forecast", "trend", "future",
                         "prevedi", "previsione", "futuro", "andrà"]),
        (.compare,      ["compare", "difference", "better", "worse", "vs",
                         "confronta", "differenza", "meglio", "peggio"]),
        (.action,       ["close", "kill", "open", "launch", "run", "do",
                         "chiudi", "termina", "avvia", "apri", "esegui", "fai"]),
    ]

    /// Keyword-based intent detection. Pure helper; the embedding-based
    /// semantic fallback stays on the instance because it depends on
    /// the loaded `NLEmbedding`. Returns `nil` when no keyword matches.
    nonisolated static func keywordIntent(for query: String) -> QueryIntent? {
        let lowered = query.lowercased()
        for (intent, keywords) in intentKeywords {
            if keywords.contains(where: { lowered.contains($0) }) {
                return intent
            }
        }
        return nil
    }

    private func detectIntent(_ query: String) -> QueryIntent {
        if let intent = Self.keywordIntent(for: query) {
            return intent
        }

        // Semantic similarity via embeddings, if available.
        if let embedding = embedding {
            let queryWords = query.split(separator: " ").map(String.init)
            var bestIntent = QueryIntent.chitchat
            var bestScore = 0.0

            for (intent, keywords) in Self.intentKeywords {
                var score = 0.0
                for word in queryWords {
                    for keyword in keywords {
                        let distance = embedding.distance(between: word, and: keyword)
                        if distance < 2.0 {
                            score += max(0, 1 - distance)
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

    // MARK: - Response building

    private func buildResponse(
        query: String,
        analysis: QueryAnalysis,
        systemContext: SystemContext
    ) async -> String {
        switch analysis.intent {
        case .statusCheck:   return buildStatusResponse(systemContext: systemContext, topics: analysis.topics)
        case .troubleshoot:  return buildTroubleshootResponse(systemContext: systemContext, query: query)
        case .optimize:      return buildOptimizeResponse(systemContext: systemContext)
        case .explain:       return buildExplainResponse(query: query, systemContext: systemContext)
        case .predict:       return Self.buildPredictResponse(prediction: systemContext.prediction)
        case .compare:       return buildCompareResponse(query: query, systemContext: systemContext)
        case .action:        return buildActionResponse(query: query, systemContext: systemContext)
        case .chitchat:      return buildChitchatResponse(query: query, sentiment: analysis.sentiment)
        }
    }

    // MARK: - Response templates

    private func buildStatusResponse(systemContext: SystemContext, topics: [String]) -> String {
        let cpu = systemContext.cpuUsage
        let mem = systemContext.memoryPressure
        let temp = systemContext.temperature

        let focusCPU    = topics.contains(where: { $0.lowercased().contains("cpu") || $0.lowercased().contains("processor") || $0.lowercased().contains("processore") })
        let focusMemory = topics.contains(where: { $0.lowercased().contains("memory") || $0.lowercased().contains("ram") || $0.lowercased().contains("memoria") })
        let focusTemp   = topics.contains(where: { $0.lowercased().contains("temp") || $0.lowercased().contains("hot") || $0.lowercased().contains("caldo") })

        var parts: [String] = []

        let healthScore = Self.calculateHealthScore(cpu: cpu, memory: mem, temp: temp)
        let healthEmoji = Self.healthEmoji(forScore: healthScore)

        if !focusCPU && !focusMemory && !focusTemp {
            parts.append("\(healthEmoji) **Overall: \(Self.healthDescriptor(forScore: healthScore))**")
            parts.append("")
        }

        if !focusMemory && !focusTemp || focusCPU {
            let cpuStatus = cpu > 80 ? "high" : (cpu > 50 ? "moderate" : "normal")
            parts.append("• **CPU**: \(Int(cpu))% (\(cpuStatus))")
        }

        if !focusCPU && !focusTemp || focusMemory {
            let memStatus = mem > 70 ? "under pressure" : (mem > 40 ? "moderate" : "ok")
            parts.append("• **Memory**: \(Int(mem))% (\(memStatus))")
        }

        if !focusCPU && !focusMemory || focusTemp {
            let tempStatus = temp > 85 ? "high" : (temp > 65 ? "normal" : "low")
            parts.append("• **Temperature**: \(Int(temp))°C (\(tempStatus))")
        }

        if let prediction = systemContext.prediction, prediction.isAnomaly {
            parts.append("")
            parts.append("🤖 **ML detection**: anomaly detected (\(prediction.anomalyType ?? "unknown")) with \(Int(prediction.confidence * 100))% confidence")
        }

        if !systemContext.activeAdvice.isEmpty {
            parts.append("")
            parts.append("**Active advice:**")
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
            issues.append("CPU at \(Int(cpu))%")
            solutions.append("Close apps you aren't using, or check Activity Monitor for runaway processes.")
        }

        if mem > 70 {
            issues.append("Memory under pressure (\(Int(mem))%)")
            solutions.append("Close unused browser tabs or restart memory-heavy apps.")
        }

        if temp > 85 {
            issues.append("Elevated temperature (\(Int(temp))°C)")
            solutions.append("Improve ventilation around the Mac or reduce the workload.")
        }

        if !systemContext.anomalies.isEmpty {
            issues.append(contentsOf: systemContext.anomalies)
        }

        if issues.isEmpty {
            return """
            🔍 **Diagnosis complete**

            I didn't find any obvious problems. The system looks normal.

            If it still feels slow, it could be:
            • A specific app (check Activity Monitor)
            • A nearly-full or fragmented disk
            • Network problems
            """
        }

        var response = "🔧 **Issues detected:**\n\n"
        for issue in issues {
            response += "• \(issue)\n"
        }

        response += "\n**Suggested fixes:**\n\n"
        for (i, solution) in solutions.enumerated() {
            response += "\(i + 1). \(solution)\n"
        }

        return response
    }

    private func buildOptimizeResponse(systemContext: SystemContext) -> String {
        var suggestions: [String] = []

        if systemContext.memoryPressure > 50 {
            suggestions.append("**Free up memory**: close background apps you aren't using")
        }

        if systemContext.cpuUsage > 40 {
            suggestions.append("**Reduce CPU load**: identify heavy processes in Activity Monitor")
        }

        if systemContext.temperature > 70 {
            suggestions.append("**Cool the Mac**: improve airflow or use a cooling pad")
        }

        suggestions.append("**Maintenance**: restart the Mac periodically to free up resources")
        suggestions.append("**Storage**: keep at least 20 GB free on the disk")

        return """
        ⚡ **Optimization suggestions:**

        \(suggestions.map { "• \($0)" }.joined(separator: "\n"))

        💡 **Tip**: the best optimization is usually closing what you don't need.
        """
    }

    private func buildExplainResponse(query: String, systemContext: SystemContext) -> String {
        let lowercased = query.lowercased()

        if lowercased.contains("cpu") {
            return """
            📚 **CPU (Central Processing Unit)**

            The CPU is the Mac's brain. The usage figure shows how hard it's working.

            • **0–30%**: idle, normal for light use
            • **30–60%**: moderate (browsing, documents)
            • **60–80%**: heavy load (video editing, compiling)
            • **80–100%**: maxed out — things may slow down

            Right now: **\(Int(systemContext.cpuUsage))%**
            """
        }

        if lowercased.contains("memory") || lowercased.contains("ram") || lowercased.contains("pressure")
            || lowercased.contains("memoria") {
            return """
            📚 **Memory pressure**

            How hard the system is working to manage memory.

            • **Green (0–50%)**: plenty of memory
            • **Yellow (50–80%)**: compression active — normal
            • **Red (80–100%)**: swapping to disk — things slow down

            Right now: **\(Int(systemContext.memoryPressure))%**

            macOS manages memory smartly: high "memory used" isn't a problem as long as pressure stays low.
            """
        }

        if lowercased.contains("temperature") || lowercased.contains("temp")
            || lowercased.contains("temperatura") || lowercased.contains("caldo") {
            return """
            📚 **CPU temperature**

            Apple Silicon is designed to run up to ~100°C with thermal throttling.

            • **< 50°C**: idle or light load
            • **50–75°C**: normal use
            • **75–95°C**: heavy load — normal
            • **> 95°C**: thermal throttling kicks in

            Right now: **\(Int(systemContext.temperature))°C**

            Fanless Macs (Air) reach higher temperatures.
            """
        }

        return """
        🤔 I'm not sure what to explain.

        I can explain:
        • **CPU** and processor usage
        • **Memory** and memory pressure
        • **Temperature** and thermal throttling

        Try: "Explain what memory pressure means."
        """
    }

    /// Pure formatter — exposed as static so tests can pin the exact
    /// rendering without spinning up the @MainActor singleton.
    nonisolated static func buildPredictResponse(prediction: AnomalyPredictionInfo?) -> String {
        guard let prediction = prediction else {
            return """
            🔮 **Prediction not available**

            The ML model hasn't been trained on your data yet.

            Keep using smol to collect samples, then:
            1. Train the model in AI → Insights
            2. Get predictions tailored to your Mac
            """
        }

        var lines: [String] = [
            "🔮 **ML prediction**",
            "",
            "Based on the patterns learned from your usage:",
            "",
            "• **Predicted CPU**: ~\(Int(prediction.predictedCPU))%",
            "• **Predicted memory**: ~\(Int(prediction.predictedMemory))%",
            "• **Predicted temperature**: ~\(Int(prediction.predictedTemp))°C",
            "",
            "**Status**: \(prediction.isAnomaly ? "⚠️ anomaly detected" : "✅ normal behaviour")",
            "**Confidence**: \(Int(prediction.confidence * 100))%",
        ]

        // The old multi-line literal always emitted a trailing
        // empty-string interpolation when `isAnomaly == false`, which
        // produced a stray blank line at the end of the response.
        // Only append the anomaly-type line when we actually have a
        // type to display.
        if prediction.isAnomaly, let type = prediction.anomalyType {
            lines.append("")
            lines.append("Type: \(type)")
        }

        return lines.joined(separator: "\n")
    }

    private func buildCompareResponse(query: String, systemContext: SystemContext) -> String {
        return """
        📊 **Snapshot vs. typical**

        | Metric | Now | Typical | Status |
        |--------|-----|---------|--------|
        | CPU | \(Int(systemContext.cpuUsage))% | 20–40% | \(systemContext.cpuUsage > 50 ? "⬆️" : "✅") |
        | Memory | \(Int(systemContext.memoryPressure))% | 30–50% | \(systemContext.memoryPressure > 60 ? "⬆️" : "✅") |
        | Temp | \(Int(systemContext.temperature))°C | 45–65°C | \(systemContext.temperature > 75 ? "⬆️" : "✅") |

        For more detailed comparisons, tell me what to compare.
        """
    }

    private func buildActionResponse(query: String, systemContext: SystemContext) -> String {
        let lowercased = query.lowercased()

        if lowercased.contains("activity monitor") || lowercased.contains("monitoraggio attività") {
            return """
            📱 **Open Activity Monitor**

            A few ways to get there:
            1. **Spotlight**: ⌘+Space → "Activity Monitor"
            2. **Finder**: Applications → Utilities → Activity Monitor
            3. **Through smol**: click the action in the advice card

            Want me to open it for you?
            """
        }

        return """
        🎬 **Available actions**

        I can help you:
        • Open Activity Monitor
        • Show processes using the most resources
        • Generate a system report

        What would you like to do?
        """
    }

    private func buildChitchatResponse(query: String, sentiment: Double) -> String {
        if sentiment < -0.3 {
            return """
            Sorry you're running into trouble. 😟

            Tell me what's happening and I'll try to help.

            Try asking:
            • "Why is the Mac slow?"
            • "How is the system doing?"
            • "What should I optimize?"
            """
        }

        return """
        Hi! 👋 I'm smol's AI assistant.

        I can help with:
        • 📊 **System status**: "How is the Mac doing?"
        • 🔧 **Problems**: "Why is it slow?"
        • ⚡ **Optimization**: "How can I speed it up?"
        • 📚 **Explanations**: "What is memory pressure?"
        • 🔮 **Predictions**: "Forecast any problems?"

        What do you want to know?
        """
    }

    // MARK: - Helpers

    /// Coarse health score (0-100) for conversational responses.
    /// Distinct from `SystemReportGenerator.calculateHealthScore` —
    /// this version uses two CPU/memory bands (50/80) and two temp
    /// bands (75/90) and ignores anomalies, since the conversational
    /// surface speaks in larger buckets than the formal report.
    nonisolated static func calculateHealthScore(cpu: Double, memory: Double, temp: Double) -> Int {
        var score = 100

        if cpu > 80 { score -= 25 }
        else if cpu > 50 { score -= 10 }

        if memory > 80 { score -= 25 }
        else if memory > 50 { score -= 10 }

        if temp > 90 { score -= 25 }
        else if temp > 75 { score -= 10 }

        return max(0, score)
    }

    nonisolated static func healthDescriptor(forScore score: Int) -> String {
        switch score {
        case 90...100: return "Excellent"
        case 70..<90:  return "Good"
        case 50..<70:  return "Moderate"
        case 30..<50:  return "Poor"
        default:       return "Critical"
        }
    }

    /// Emoji aligned to `healthDescriptor` bands. Previously the emoji
    /// used `> 80` / `> 50` thresholds while the descriptor used
    /// 90/70/50/30, so a score of 75 displayed as "Good" with a ⚠️
    /// emoji — the descriptor said "good" while the emoji said
    /// "warning". Now Excellent/Good → ✅, Moderate → ⚠️,
    /// Poor/Critical → 🔴.
    nonisolated static func healthEmoji(forScore score: Int) -> String {
        if score >= 70 { return "✅" }
        if score >= 50 { return "⚠️" }
        return "🔴"
    }

    // MARK: - Context persistence

    private var contextFileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("smol/conversation_context.json")
    }

    private func addToContext(role: String, content: String, sentiment: Double?, topics: [String]) {
        let item = ContextItem(
            role: role,
            content: content,
            timestamp: Date(),
            sentiment: sentiment,
            topics: topics
        )

        conversationContext.append(item)

        if conversationContext.count > maxContextItems {
            conversationContext.removeFirst(conversationContext.count - maxContextItems)
        }

        saveContext()
    }

    private func saveContext() {
        guard let url = contextFileURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(conversationContext) {
            try? data.write(to: url)
        }
    }

    private func loadContext() {
        guard let url = contextFileURL,
              let data = try? Data(contentsOf: url),
              let context = try? JSONDecoder().decode([ContextItem].self, from: data) else {
            return
        }
        conversationContext = context
    }

    func clearContext() {
        conversationContext = []
        saveContext()
    }
}
