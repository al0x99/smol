import Foundation
import Testing
@testable import smol

// MARK: - NaturalLanguageProcessor
//
// This is the template-fallback path that runs when the LLM
// backends are unavailable (no API key, network failure, etc.).
// It has to classify a query into a `QueryIntent` and emit a
// reasonable-looking string. The classifier is bilingual — both
// English and Italian phrasing have to land on the same intent.
// The tests below pin both the EN/IT keyword coverage and the
// `?`-as-question detection that the prior `analyzeWithNLP`
// implementation got wrong (it watched for `.particle` tokens
// containing `?`, but NLTagger classifies `?` as `.punctuation`).

struct NaturalLanguageProcessorIntentTests {

    private func ask(_ query: String) -> String {
        NaturalLanguageProcessor().processQuery(
            query,
            cpuHistory: [],
            memoryHistory: [],
            tempHistory: [],
            currentAdvice: [],
            anomalies: []
        )
    }

    // MARK: - Intent: CPU

    @Test func englishCPUKeywordHitsCPUResponse() {
        let r = ask("How is the CPU?")
        #expect(r.contains("CPU at"))
    }

    @Test func italianProcessoreKeywordHitsCPUResponse() {
        let r = ask("Che fa il processore?")
        #expect(r.contains("CPU at"))
    }

    // MARK: - Intent: Memory

    @Test func englishRAMKeywordHitsMemoryResponse() {
        let r = ask("Anything weird with RAM?")
        // "weird" is also an anomaly keyword, so just make sure the
        // memory branch can be reached at all via "ram".
        let r2 = ask("How is RAM doing")
        #expect(r2.contains("Memory pressure"))
        // The original keeps `r` as a sanity check that the function
        // returned something.
        #expect(!r.isEmpty)
    }

    @Test func italianMemoriaKeywordHitsMemoryResponse() {
        let r = ask("Come va la memoria")
        #expect(r.contains("Memory pressure"))
    }

    // MARK: - Intent: Temperature

    @Test func englishTemperatureKeywordHitsTempResponse() {
        let r = ask("What is the temperature")
        #expect(r.contains("CPU temperature"))
    }

    @Test func italianTemperaturaKeywordHitsTempResponse() {
        let r = ask("Che temperatura abbiamo")
        #expect(r.contains("CPU temperature"))
    }

    // MARK: - Intent: Why Slow

    @Test func englishSlowKeywordHitsWhySlowResponse() {
        let r = ask("Why is my mac so slow")
        // Empty advice + 0% metrics means "normally" branch fires.
        #expect(r.contains("normally") || r.contains("running"))
    }

    @Test func italianLentoKeywordHitsWhySlowResponse() {
        let r = ask("perché è lento")
        #expect(r.contains("normally") || r.contains("running"))
    }

    // MARK: - Intent: What to close

    @Test func englishCloseKeywordHitsWhatToCloseResponse() {
        let r = ask("which app should I close")
        // No advice → "nothing needs closing" branch.
        #expect(r.contains("nothing needs closing") || r.contains("doing fine"))
    }

    @Test func italianChiudereKeywordHitsWhatToCloseResponse() {
        let r = ask("cosa devo chiudere")
        #expect(r.contains("nothing needs closing") || r.contains("doing fine"))
    }

    // MARK: - Intent: Anomalies

    @Test func englishAnomalyKeywordWithNoAnomaliesReturnsNoneMessage() {
        let r = ask("any anomaly")
        #expect(r.contains("No anomalies detected"))
    }

    @Test func italianAnomaliaKeywordWithNoAnomaliesReturnsNoneMessage() {
        let r = ask("qualche anomalia")
        #expect(r.contains("No anomalies detected"))
    }

    // MARK: - Intent: Process

    @Test func englishProcessKeywordWithProperNounExtractsName() {
        let r = ask("how is Chrome process running")
        // "process" → processInfo branch → extracts "Chrome" as the
        // capitalized fallback (NLTagger sees it as a noun rather than
        // an organization, but the fallback catches it).
        #expect(r.contains("'Chrome'"))
    }

    @Test func englishProcessKeywordWithNoNameAsksForOne() {
        let r = ask("any process to watch")
        // No proper noun in the query → fallback prompt.
        #expect(r.contains("Tell me the process name"))
    }

    // MARK: - Question detection (the bug-fix path)

    @Test func barePunctuationQuestionFallsThroughToGeneralStatus() {
        // No keyword match in any set → `analyzeWithNLP` should still
        // recognise it as a question via the `?` mark and route to
        // `.generalStatus`. Pre-fix this returned `.unknown` because
        // NLTagger doesn't classify `?` as `.particle`.
        let r = ask("Tutto ok lì dentro?")
        // generalStatus response always starts with "The system is ".
        #expect(r.contains("The system is"))
    }

    @Test func englishHowKeywordOutsideAnyTopicTriggersGeneralStatus() {
        // "how" is the legacy English fallback in `analyzeWithNLP`.
        let r = ask("how are things")
        #expect(r.contains("The system is"))
    }

    @Test func italianComeKeywordOutsideAnyTopicTriggersGeneralStatus() {
        // "come" is the legacy Italian fallback in `analyzeWithNLP`.
        let r = ask("come stai")
        #expect(r.contains("The system is"))
    }

    @Test func capitalizedHowAlsoTriggersGeneralStatus() {
        // Pre-fix the check was `query.contains("how")` (case-
        // sensitive), so a sentence starting with "How " missed the
        // keyword fallback. The fix lowercases first.
        let r = ask("How are we doing")
        #expect(r.contains("The system is"))
    }

    @Test func gibberishWithoutQuestionMarkOrKeywordsReturnsUnknownPrompt() {
        let r = ask("xyzzy quux blargh")
        // Unknown response starts with this exact phrase.
        #expect(r.contains("I didn't quite catch that"))
    }
}
