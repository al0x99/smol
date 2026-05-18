import Foundation
import Testing
@testable import smol

// MARK: - SystemReportGenerator pure-logic tests
//
// We pin the parts of the report that are timestamp-independent:
// the health-score rule (per-band deductions for CPU/memory/temp
// + anomaly penalties), the bucket label that the summary line
// derives from that score, and one regression test for the
// `exportAsText` formatter — the RECOMMENDATIONS underline used
// to glue itself to the first recommendation because Swift
// triple-quoted literals strip the newline before the closing
// `"""`. The end-to-end `generate(...)` path is left to live
// usage; it's mostly composition over the parts tested here.

// MARK: - Health-score rule

struct SystemReportHealthScoreTests {

    private typealias Gen = SystemReportGenerator

    private func points(_ values: [Double]) -> [AIDataPoint] {
        let now = Date()
        return values.enumerated().map { i, v in
            AIDataPoint(timestamp: now.addingTimeInterval(Double(i)), value: v)
        }
    }

    private func anomaly(confidence: Double) -> AIAnomaly {
        AIAnomaly(
            type: .cpuSpike,
            description: "test",
            detectedAt: Date(),
            confidence: confidence,
            relatedMetric: "CPU",
            currentValue: 50,
            expectedRange: 0...100
        )
    }

    @Test func emptyEverythingReturnsFullScore() {
        // No data, no anomalies — nothing to deduct. The "no info"
        // state should not look worse than a healthy system.
        let score = Gen.calculateHealthScore(
            cpuHistory: [],
            memoryHistory: [],
            tempHistory: [],
            anomalies: []
        )
        #expect(score == 100)
    }

    @Test func quietSystemReturnsFullScore() {
        // CPU 10, memory 20, temp 50 — all below the lowest
        // deduction band (>40 / >40 / >70).
        let score = Gen.calculateHealthScore(
            cpuHistory: points([10, 10, 10]),
            memoryHistory: points([20, 20, 20]),
            tempHistory: points([50, 50, 50]),
            anomalies: []
        )
        #expect(score == 100)
    }

    @Test func cpuDeductionBands() {
        // The CPU bands are strict-`>` at 80/60/40. Pin every
        // boundary so a refactor that flips `>` to `>=` breaks
        // a test instead of silently moving the score.
        let exactly40 = Gen.calculateHealthScore(
            cpuHistory: points([40]), memoryHistory: [], tempHistory: [], anomalies: []
        )
        let just41 = Gen.calculateHealthScore(
            cpuHistory: points([41]), memoryHistory: [], tempHistory: [], anomalies: []
        )
        let just61 = Gen.calculateHealthScore(
            cpuHistory: points([61]), memoryHistory: [], tempHistory: [], anomalies: []
        )
        let just81 = Gen.calculateHealthScore(
            cpuHistory: points([81]), memoryHistory: [], tempHistory: [], anomalies: []
        )
        #expect(exactly40 == 100) // boundary excluded
        #expect(just41 == 95)     // -5
        #expect(just61 == 85)     // -15
        #expect(just81 == 75)     // -25
    }

    @Test func memoryDeductionBands() {
        let just41 = Gen.calculateHealthScore(
            cpuHistory: [], memoryHistory: points([41]), tempHistory: [], anomalies: []
        )
        let just61 = Gen.calculateHealthScore(
            cpuHistory: [], memoryHistory: points([61]), tempHistory: [], anomalies: []
        )
        let just81 = Gen.calculateHealthScore(
            cpuHistory: [], memoryHistory: points([81]), tempHistory: [], anomalies: []
        )
        #expect(just41 == 95)
        #expect(just61 == 85)
        #expect(just81 == 75)
    }

    @Test func temperatureDeductionBands() {
        // Temp bands use 70/80/90 instead of 40/60/80 — pin so a
        // refactor that copies the CPU/memory thresholds into
        // temp gets caught.
        let just71 = Gen.calculateHealthScore(
            cpuHistory: [], memoryHistory: [], tempHistory: points([71]), anomalies: []
        )
        let just81 = Gen.calculateHealthScore(
            cpuHistory: [], memoryHistory: [], tempHistory: points([81]), anomalies: []
        )
        let just91 = Gen.calculateHealthScore(
            cpuHistory: [], memoryHistory: [], tempHistory: points([91]), anomalies: []
        )
        #expect(just71 == 95)
        #expect(just81 == 85)
        #expect(just91 == 75)
    }

    @Test func criticalAnomalyDeducts10Each() {
        let one = Gen.calculateHealthScore(
            cpuHistory: [], memoryHistory: [], tempHistory: [],
            anomalies: [anomaly(confidence: 0.9)]
        )
        let three = Gen.calculateHealthScore(
            cpuHistory: [], memoryHistory: [], tempHistory: [],
            anomalies: [anomaly(confidence: 0.9), anomaly(confidence: 0.95), anomaly(confidence: 1.0)]
        )
        #expect(one == 90)
        #expect(three == 70)
    }

    @Test func warningAnomalyDeducts5Each() {
        let one = Gen.calculateHealthScore(
            cpuHistory: [], memoryHistory: [], tempHistory: [],
            anomalies: [anomaly(confidence: 0.7)]
        )
        let two = Gen.calculateHealthScore(
            cpuHistory: [], memoryHistory: [], tempHistory: [],
            anomalies: [anomaly(confidence: 0.6), anomaly(confidence: 0.75)]
        )
        #expect(one == 95)
        #expect(two == 90)
    }

    @Test func confidenceAtExactly08CountsAsWarningNotCritical() {
        // This pins the `<= 0.8` upper bound on the warning band.
        // Flipping to `< 0.8` would silently drop the anomaly out
        // of the score entirely (since the critical band uses
        // `> 0.8` not `>= 0.8`); flipping the critical band to
        // `>= 0.8` would double-deduct.
        let score = Gen.calculateHealthScore(
            cpuHistory: [], memoryHistory: [], tempHistory: [],
            anomalies: [anomaly(confidence: 0.8)]
        )
        #expect(score == 95) // warning deduction, not critical
    }

    @Test func confidenceAtExactly05IsNotCounted() {
        // The warning band starts at strict-`> 0.5`, so a
        // confidence of exactly 0.5 contributes zero. This is
        // the "barely above chance" band and shouldn't ding
        // the score.
        let score = Gen.calculateHealthScore(
            cpuHistory: [], memoryHistory: [], tempHistory: [],
            anomalies: [anomaly(confidence: 0.5)]
        )
        #expect(score == 100)
    }

    @Test func deductionsFloorAtZero() {
        // Every band maxed plus a pile of critical anomalies —
        // the raw score would go negative without the clamp.
        let manyAnomalies = (0..<20).map { _ in anomaly(confidence: 0.95) }
        let score = Gen.calculateHealthScore(
            cpuHistory: points([95, 95, 95]),
            memoryHistory: points([95, 95, 95]),
            tempHistory: points([95, 95, 95]),
            anomalies: manyAnomalies
        )
        #expect(score == 0)
    }
}

// MARK: - Health-status label boundaries

struct SystemReportHealthStatusLabelTests {

    private typealias Gen = SystemReportGenerator

    @Test func excellentBandIncludesBoth90And100() {
        #expect(Gen.healthStatusLabel(forScore: 100) == "excellent")
        #expect(Gen.healthStatusLabel(forScore: 95) == "excellent")
        #expect(Gen.healthStatusLabel(forScore: 90) == "excellent")
    }

    @Test func score89IsGoodNotExcellent() {
        // 90 is the inclusive lower bound of "excellent", so 89
        // is the inclusive upper bound of "good". The summary
        // line surfaces this label directly to users, so a band
        // drift would be visible immediately.
        #expect(Gen.healthStatusLabel(forScore: 89) == "good")
    }

    @Test func goodBandSpans70To89() {
        #expect(Gen.healthStatusLabel(forScore: 70) == "good")
        #expect(Gen.healthStatusLabel(forScore: 80) == "good")
        #expect(Gen.healthStatusLabel(forScore: 89) == "good")
    }

    @Test func moderateBandSpans50To69() {
        #expect(Gen.healthStatusLabel(forScore: 50) == "moderate")
        #expect(Gen.healthStatusLabel(forScore: 60) == "moderate")
        #expect(Gen.healthStatusLabel(forScore: 69) == "moderate")
    }

    @Test func poorBandSpans30To49() {
        #expect(Gen.healthStatusLabel(forScore: 30) == "poor")
        #expect(Gen.healthStatusLabel(forScore: 40) == "poor")
        #expect(Gen.healthStatusLabel(forScore: 49) == "poor")
    }

    @Test func belowThirtyIsCritical() {
        #expect(Gen.healthStatusLabel(forScore: 29) == "critical")
        #expect(Gen.healthStatusLabel(forScore: 0) == "critical")
    }
}

// MARK: - exportAsText formatter

struct SystemReportExportAsTextTests {

    private func makeReport(recommendations: [String]) -> SystemReport {
        SystemReport(
            generatedAt: Date(timeIntervalSince1970: 0),
            summary: "ok.",
            healthScore: 100,
            sections: [],
            recommendations: recommendations
        )
    }

    @Test func recommendationsAreNotGluedToUnderline() {
        // Regression: the multi-line literal used to drop the
        // trailing newline immediately before `"""`, producing
        // `────────────────1. First rec` on one line. We pin
        // that the underline and the first recommendation are
        // separated by at least a newline, never adjacent.
        let generator = SystemReportGenerator()
        let report = makeReport(recommendations: ["First rec", "Second rec"])
        let text = generator.exportAsText(report)

        #expect(text.contains("────────────────\n"))
        #expect(!text.contains("────────────────1."))
        #expect(text.contains("1. First rec"))
        #expect(text.contains("2. Second rec"))
    }

    @Test func recommendationsAreNumberedFromOne() {
        // Three recommendations → "1.", "2.", "3." exactly. Pins
        // both the start (1-based, not 0-based) and the increment.
        let generator = SystemReportGenerator()
        let report = makeReport(recommendations: ["a", "b", "c"])
        let text = generator.exportAsText(report)
        #expect(text.contains("1. a"))
        #expect(text.contains("2. b"))
        #expect(text.contains("3. c"))
        #expect(!text.contains("0. "))
    }

    @Test func reportContainsHealthScoreLine() {
        // The SUMMARY block is a known field the user might
        // copy-paste; pin the "Health score: N/100" exact form so
        // the surrounding text can change but this line stays
        // recognizable.
        let generator = SystemReportGenerator()
        let report = SystemReport(
            generatedAt: Date(),
            summary: "ok.",
            healthScore: 78,
            sections: [],
            recommendations: []
        )
        let text = generator.exportAsText(report)
        #expect(text.contains("Health score: 78/100"))
    }
}
