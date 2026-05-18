import Foundation
import Testing
@testable import smol

// MARK: - LocalLLMEngine pure-logic tests
//
// LocalLLMEngine is the template-based fallback chat engine, a
// @MainActor ObservableObject with a singleton, an NLEmbedding, and
// JSON-backed conversation context. We can't drive it end-to-end
// without the embedding model and the user's Application Support
// directory, but the pieces below are pure and worth pinning:
//
//   - `keywordIntent(for:)`: the bilingual keyword classifier. The
//     priority used to live in a `[QueryIntent: [String]]` dict, so
//     the returned intent for ambiguous queries was decided by Swift's
//     per-process hash seed and could shift across runs. The new
//     ordered-tuple table is deterministic; we pin the ordering.
//   - `calculateHealthScore` / `healthDescriptor` / `healthEmoji`:
//     the conversational health rules. Distinct from
//     SystemReportGenerator's — these use coarser bands. We pin the
//     bands so a "let's unify them" refactor breaks here before
//     changing strings the chat UI relies on. We also pin the new
//     descriptor↔emoji alignment so "Good" never displays with ⚠️
//     again.
//   - `buildPredictResponse`: the regression that motivated this
//     pass. The old multi-line literal interpolated an empty string
//     for non-anomaly predictions, producing a stray blank line at
//     the end of every "normal behaviour" response.

// MARK: - Intent keyword classifier

struct LocalLLMEngineIntentTests {

    private typealias Engine = LocalLLMEngine

    @Test func statusKeywordsClassifyAsStatusCheck() {
        // English
        #expect(Engine.keywordIntent(for: "what is the status?") == .statusCheck)
        #expect(Engine.keywordIntent(for: "how is the mac doing") == .statusCheck)
        #expect(Engine.keywordIntent(for: "current cpu load") == .statusCheck)
        #expect(Engine.keywordIntent(for: "system health check") == .statusCheck)
        // Italian
        #expect(Engine.keywordIntent(for: "stato attuale del sistema") == .statusCheck)
        #expect(Engine.keywordIntent(for: "come sta il mac") == .statusCheck)
        #expect(Engine.keywordIntent(for: "qual è la situazione") == .statusCheck)
    }

    @Test func troubleshootKeywords() {
        #expect(Engine.keywordIntent(for: "the mac is slow") == .troubleshoot)
        #expect(Engine.keywordIntent(for: "I have a problem") == .troubleshoot)
        #expect(Engine.keywordIntent(for: "it doesn't work") == .troubleshoot)
        #expect(Engine.keywordIntent(for: "ho un problema") == .troubleshoot)
        #expect(Engine.keywordIntent(for: "il mac è lento") == .troubleshoot)
        #expect(Engine.keywordIntent(for: "aiuto, non funziona") == .troubleshoot)
    }

    @Test func optimizeKeywords() {
        #expect(Engine.keywordIntent(for: "optimize my mac") == .optimize)
        #expect(Engine.keywordIntent(for: "speed up the system") == .optimize)
        #expect(Engine.keywordIntent(for: "improve performance") == .optimize)
        #expect(Engine.keywordIntent(for: "ottimizza il mac") == .optimize)
        #expect(Engine.keywordIntent(for: "voglio migliorare le prestazioni") == .optimize)
    }

    @Test func explainKeywords() {
        #expect(Engine.keywordIntent(for: "explain memory pressure") == .explain)
        #expect(Engine.keywordIntent(for: "what is RAM") == .explain)
        #expect(Engine.keywordIntent(for: "spiega come funziona") == .explain)
    }

    @Test func predictKeywords() {
        #expect(Engine.keywordIntent(for: "predict the cpu load") == .predict)
        #expect(Engine.keywordIntent(for: "what's the trend") == .predict)
        #expect(Engine.keywordIntent(for: "previsione futura") == .predict)
    }

    @Test func compareKeywords() {
        #expect(Engine.keywordIntent(for: "compare cpu to memory") == .compare)
        #expect(Engine.keywordIntent(for: "what's the difference") == .compare)
        #expect(Engine.keywordIntent(for: "confronta i risultati") == .compare)
    }

    @Test func actionKeywords() {
        #expect(Engine.keywordIntent(for: "kill the runaway process") == .action)
        #expect(Engine.keywordIntent(for: "open activity monitor") == .action)
        #expect(Engine.keywordIntent(for: "chiudi le app") == .action)
        #expect(Engine.keywordIntent(for: "apri il finder") == .action)
    }

    @Test func emptyQueryReturnsNil() {
        // No keywords ⇒ falls through to nil so the caller can run
        // the embedding fallback (or land on .chitchat).
        #expect(Engine.keywordIntent(for: "") == nil)
    }

    @Test func nonsenseQueryReturnsNil() {
        #expect(Engine.keywordIntent(for: "asdf qwerty xyzzy") == nil)
    }

    @Test func intentPriorityIsDeterministicForAmbiguousQueries() {
        // Regression: the keyword table used to be a
        // `[QueryIntent: [String]]` dictionary. Swift dictionary
        // iteration is in hash-seed order, randomized per process —
        // so a query matching keywords from multiple intents could
        // return different intents across runs of the same binary.
        // The fix moved the table to an ordered tuple array; this
        // test pins the priority that order encodes.
        //
        // The ordering in source is:
        //   statusCheck → troubleshoot → optimize → explain →
        //   predict → compare → action
        // …so each ambiguous query below must resolve to the
        // earlier intent.

        // "status" (statusCheck) beats "slow" (troubleshoot)
        #expect(
            Engine.keywordIntent(for: "tell me the status, the mac is slow")
            == .statusCheck
        )

        // "help" (troubleshoot) beats "optimize" (optimize)
        #expect(
            Engine.keywordIntent(for: "help me optimize the mac")
            == .troubleshoot
        )

        // "improve" (optimize) beats "explain" (explain).
        // (Careful: avoid "why" / "help" / "slow" here — those land
        // in troubleshoot, which iterates *before* optimize.)
        #expect(
            Engine.keywordIntent(for: "improve performance, please explain")
            == .optimize
        )

        // "what is" (explain) beats "forecast" (predict)
        #expect(
            Engine.keywordIntent(for: "what is the forecast for tomorrow")
            == .explain
        )

        // "trend" (predict) beats "compare" (compare)
        #expect(
            Engine.keywordIntent(for: "predict the trend and compare to last week")
            == .predict
        )

        // "compare" (compare) beats "open" (action)
        #expect(
            Engine.keywordIntent(for: "compare the apps before I open one")
            == .compare
        )
    }

    @Test func caseInsensitive() {
        // The table contains lowercase keywords, but `analyzeQuery`
        // passes a lowercased query already. We still want
        // `keywordIntent` to be safe for direct callers (and tests),
        // so it lowercases internally.
        #expect(Engine.keywordIntent(for: "STATUS report") == .statusCheck)
        #expect(Engine.keywordIntent(for: "Slow Mac") == .troubleshoot)
        #expect(Engine.keywordIntent(for: "EXPLAIN this") == .explain)
    }

    @Test func intentTableCoversAllSevenIntents() {
        // Every non-chitchat case in the QueryIntent enum should
        // have at least one keyword listed. A new intent added to
        // the enum without a keyword row would make the chat engine
        // unable to route to it via the keyword path.
        let intentsInTable = Set(Engine.intentKeywords.map { $0.intent })
        #expect(intentsInTable.contains(.statusCheck))
        #expect(intentsInTable.contains(.troubleshoot))
        #expect(intentsInTable.contains(.optimize))
        #expect(intentsInTable.contains(.explain))
        #expect(intentsInTable.contains(.predict))
        #expect(intentsInTable.contains(.compare))
        #expect(intentsInTable.contains(.action))
        // chitchat is the *default*, intentionally not in the table.
        #expect(!intentsInTable.contains(.chitchat))
    }

    @Test func keywordTableHasNoEmptyKeywordLists() {
        // Defensive: an empty keyword list would silently skip its
        // intent forever (and `contains(where:)` over an empty array
        // returns false).
        for (_, keywords) in Engine.intentKeywords {
            #expect(!keywords.isEmpty)
        }
    }
}

// MARK: - calculateHealthScore (conversational variant)

struct LocalLLMEngineHealthScoreTests {

    private typealias Engine = LocalLLMEngine

    @Test func quietSystemReturnsFullScore() {
        // CPU 30, memory 30, temp 50 — all below the lowest band.
        #expect(Engine.calculateHealthScore(cpu: 30, memory: 30, temp: 50) == 100)
    }

    @Test func cpuDeductionBands() {
        // The bands are strict-`>` at 50 and 80. Pin both boundaries
        // so a refactor flipping `>` to `>=` breaks a test instead
        // of silently moving the score.
        #expect(Engine.calculateHealthScore(cpu: 50, memory: 0, temp: 0) == 100) // boundary excluded
        #expect(Engine.calculateHealthScore(cpu: 51, memory: 0, temp: 0) == 90)
        #expect(Engine.calculateHealthScore(cpu: 80, memory: 0, temp: 0) == 90)  // boundary excluded
        #expect(Engine.calculateHealthScore(cpu: 81, memory: 0, temp: 0) == 75)
    }

    @Test func memoryDeductionBands() {
        #expect(Engine.calculateHealthScore(cpu: 0, memory: 51, temp: 0) == 90)
        #expect(Engine.calculateHealthScore(cpu: 0, memory: 81, temp: 0) == 75)
    }

    @Test func tempDeductionBands() {
        // Temp bands are 75 and 90 — distinct from CPU/memory's
        // 50 and 80. Pin so a refactor that copies the CPU bands
        // into temp gets caught.
        #expect(Engine.calculateHealthScore(cpu: 0, memory: 0, temp: 75) == 100) // boundary excluded
        #expect(Engine.calculateHealthScore(cpu: 0, memory: 0, temp: 76) == 90)
        #expect(Engine.calculateHealthScore(cpu: 0, memory: 0, temp: 90) == 90)  // boundary excluded
        #expect(Engine.calculateHealthScore(cpu: 0, memory: 0, temp: 91) == 75)
    }

    @Test func deductionsDoNotStackWithinAxis() {
        // The CPU rule is `if > 80 { -25 } else if > 50 { -10 }`, so
        // the bands replace each other within an axis (no double
        // dipping). 95 = -25, not -35.
        #expect(Engine.calculateHealthScore(cpu: 95, memory: 0, temp: 0) == 75)
    }

    @Test func deductionsStackAcrossAxes() {
        // High CPU + high memory + high temp: -25 each = -75.
        #expect(Engine.calculateHealthScore(cpu: 90, memory: 90, temp: 95) == 25)
    }

    @Test func floorsAtZero() {
        // The conversational variant doesn't track anomalies, so
        // the max deduction is -75 across the three axes — the
        // floor isn't strictly needed for this rule today, but
        // we pin it so a future "add anomaly penalty" change can't
        // accidentally produce a negative score.
        let extreme = Engine.calculateHealthScore(cpu: 99, memory: 99, temp: 99)
        #expect(extreme >= 0)
    }
}

// MARK: - healthDescriptor labels

struct LocalLLMEngineHealthDescriptorTests {

    private typealias Engine = LocalLLMEngine

    @Test func excellentBandIncludes90And100() {
        #expect(Engine.healthDescriptor(forScore: 100) == "Excellent")
        #expect(Engine.healthDescriptor(forScore: 95) == "Excellent")
        #expect(Engine.healthDescriptor(forScore: 90) == "Excellent")
    }

    @Test func goodBandSpans70To89() {
        #expect(Engine.healthDescriptor(forScore: 89) == "Good")
        #expect(Engine.healthDescriptor(forScore: 80) == "Good")
        #expect(Engine.healthDescriptor(forScore: 70) == "Good")
    }

    @Test func moderateBandSpans50To69() {
        #expect(Engine.healthDescriptor(forScore: 69) == "Moderate")
        #expect(Engine.healthDescriptor(forScore: 60) == "Moderate")
        #expect(Engine.healthDescriptor(forScore: 50) == "Moderate")
    }

    @Test func poorBandSpans30To49() {
        #expect(Engine.healthDescriptor(forScore: 49) == "Poor")
        #expect(Engine.healthDescriptor(forScore: 40) == "Poor")
        #expect(Engine.healthDescriptor(forScore: 30) == "Poor")
    }

    @Test func criticalBandBelow30() {
        #expect(Engine.healthDescriptor(forScore: 29) == "Critical")
        #expect(Engine.healthDescriptor(forScore: 0) == "Critical")
    }

    @Test func descriptorLabelsAreCapitalized() {
        // SystemReportGenerator's healthStatusLabel returns lowercase
        // strings ("excellent"); this engine returns Title Case for
        // conversational display. The bands are the same (90/70/50/30)
        // but the strings deliberately differ. Pin so a "let's unify
        // them" refactor breaks here before changing UI strings.
        #expect(Engine.healthDescriptor(forScore: 100) == "Excellent")
        #expect(Engine.healthDescriptor(forScore: 100) != "excellent")
    }
}

// MARK: - healthEmoji alignment

struct LocalLLMEngineHealthEmojiTests {

    private typealias Engine = LocalLLMEngine

    @Test func emojiAlignsWithDescriptorBands() {
        // Regression: the emoji used to use `> 80` / `> 50` thresholds
        // while the descriptor used 90/70/50/30. A score of 75 would
        // display as "Good" with a ⚠️ emoji — the words said "good",
        // the symbol said "warning". The fix realigns the emoji to
        // the descriptor's positive (>=70), neutral (>=50), and
        // negative (<50) groupings:
        //   Excellent (90+) / Good (70-89) → ✅
        //   Moderate (50-69)              → ⚠️
        //   Poor (30-49) / Critical (<30) → 🔴
        #expect(Engine.healthEmoji(forScore: 100) == "✅") // Excellent
        #expect(Engine.healthEmoji(forScore: 90) == "✅")  // Excellent boundary
        #expect(Engine.healthEmoji(forScore: 80) == "✅")  // Good
        #expect(Engine.healthEmoji(forScore: 75) == "✅")  // Good — was ⚠️ before fix
        #expect(Engine.healthEmoji(forScore: 70) == "✅")  // Good boundary
        #expect(Engine.healthEmoji(forScore: 69) == "⚠️")  // Moderate
        #expect(Engine.healthEmoji(forScore: 50) == "⚠️")  // Moderate boundary — was 🔴 before fix
        #expect(Engine.healthEmoji(forScore: 49) == "🔴")  // Poor
        #expect(Engine.healthEmoji(forScore: 30) == "🔴")  // Poor boundary
        #expect(Engine.healthEmoji(forScore: 0) == "🔴")   // Critical
    }

    @Test func everyDescriptorBucketGetsConsistentEmoji() {
        // Pair the two functions: for every band the descriptor
        // claims, the emoji must agree with the band's polarity.
        // This guards against the next drift before it happens.
        for score in 0...100 {
            let descriptor = Engine.healthDescriptor(forScore: score)
            let emoji = Engine.healthEmoji(forScore: score)
            switch descriptor {
            case "Excellent", "Good":
                #expect(emoji == "✅", "score \(score) → \(descriptor) but emoji \(emoji)")
            case "Moderate":
                #expect(emoji == "⚠️", "score \(score) → \(descriptor) but emoji \(emoji)")
            case "Poor", "Critical":
                #expect(emoji == "🔴", "score \(score) → \(descriptor) but emoji \(emoji)")
            default:
                Issue.record("unexpected descriptor \(descriptor) for score \(score)")
            }
        }
    }
}

// MARK: - buildPredictResponse formatter

struct LocalLLMEngineBuildPredictResponseTests {

    private typealias Engine = LocalLLMEngine

    private func prediction(
        isAnomaly: Bool,
        anomalyType: String? = nil,
        confidence: Double = 0.85,
        cpu: Double = 25,
        memory: Double = 40,
        temp: Double = 55
    ) -> Engine.AnomalyPredictionInfo {
        Engine.AnomalyPredictionInfo(
            isAnomaly: isAnomaly,
            confidence: confidence,
            anomalyType: anomalyType,
            predictedCPU: cpu,
            predictedMemory: memory,
            predictedTemp: temp
        )
    }

    @Test func nilPredictionShowsTrainingHint() {
        let text = Engine.buildPredictResponse(prediction: nil)
        #expect(text.contains("Prediction not available"))
        #expect(text.contains("Train the model"))
    }

    @Test func normalBehaviourHasNoTrailingBlank() {
        // Regression: the old multi-line literal always interpolated
        //   \(prediction.isAnomaly ? ... : "")
        // on its own line, producing a stray blank line at the end
        // of every "normal behaviour" response. Pin that the
        // response ends *exactly* on the Confidence line.
        let text = Engine.buildPredictResponse(
            prediction: prediction(isAnomaly: false, confidence: 0.85)
        )
        #expect(text.hasSuffix("**Confidence**: 85%"))
        #expect(text.contains("normal behaviour"))
        #expect(!text.contains("Type:"))
    }

    @Test func anomalyWithTypeAppendsTypeLine() {
        let text = Engine.buildPredictResponse(
            prediction: prediction(
                isAnomaly: true,
                anomalyType: "cpu_spike",
                confidence: 0.9
            )
        )
        #expect(text.contains("anomaly detected"))
        #expect(text.hasSuffix("Type: cpu_spike"))
    }

    @Test func anomalyWithoutTypeOmitsTypeLine() {
        // Edge: isAnomaly == true but anomalyType == nil. The old
        // code used `(prediction.anomalyType.map { "Type: \($0)" } ?? "")`
        // which produced an empty interpolation and the same trailing
        // blank as the non-anomaly path. The new code omits the line.
        let text = Engine.buildPredictResponse(
            prediction: prediction(isAnomaly: true, anomalyType: nil, confidence: 0.7)
        )
        #expect(text.hasSuffix("**Confidence**: 70%"))
        #expect(!text.contains("Type:"))
        // The "anomaly detected" status still appears even without
        // a type label — the absence of a type doesn't change the
        // top-line verdict.
        #expect(text.contains("anomaly detected"))
    }

    @Test func confidencePercentageIsRounded() {
        // 0.876 → 87% (Int truncates). Pin so a refactor to
        // `(rounded * 100)` doesn't silently shift display values.
        let text = Engine.buildPredictResponse(
            prediction: prediction(isAnomaly: false, confidence: 0.876)
        )
        #expect(text.contains("**Confidence**: 87%"))
    }

    @Test func predictedMetricsAreRendered() {
        let text = Engine.buildPredictResponse(
            prediction: prediction(
                isAnomaly: false,
                cpu: 72.3, memory: 45.6, temp: 81.9
            )
        )
        #expect(text.contains("Predicted CPU**: ~72%"))
        #expect(text.contains("Predicted memory**: ~45%"))
        // Temperature uses °C (not %); the formatter intentionally
        // differentiates the unit on the temp line.
        #expect(text.contains("Predicted temperature**: ~81°C"))
    }
}
