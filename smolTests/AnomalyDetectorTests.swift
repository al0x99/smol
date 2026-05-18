import Foundation
import Testing
@testable import smol

// MARK: - AnomalyDetector pure logic
//
// AnomalyDetector emits the `AIAnomaly` entries that drive the
// Anomalies tab and the AI assistant's situational warnings. Two
// chunks of its math are non-trivial enough to be worth pinning down
// against a kernel-free fixture:
//
//   * `linearRegressionFit` — the slope+R² engine behind the
//     "memory pressure keeps climbing" leak heuristic.
//   * `oscillationScore` — the direction-reversal counter that flags
//     a process repeatedly starting and stopping.
//
// They are both pure transforms of `[Double]`, so the tests below
// drive them directly with synthetic series rather than wiring up a
// SystemMonitor stub.

struct AnomalyDetectorRegressionTests {

    @Test func emptySeriesReturnsNil() {
        #expect(AnomalyDetector.linearRegressionFit([]) == nil)
    }

    @Test func singleSampleReturnsNil() {
        // A line needs two points. One sample carries no slope.
        #expect(AnomalyDetector.linearRegressionFit([42]) == nil)
    }

    @Test func perfectAscendingLineHasSlopeOneAndPerfectFit() {
        let fit = AnomalyDetector.linearRegressionFit([0, 1, 2, 3, 4, 5])
        #expect(fit != nil)
        guard let fit else { return }
        #expect(abs(fit.slope - 1.0) < 1e-9)
        #expect(abs(fit.rSquared - 1.0) < 1e-9)
    }

    @Test func perfectDescendingLineHasNegativeSlope() {
        // Memory pressure dropping over time isn't a leak — slope must
        // come back negative so the caller filters it out.
        let fit = AnomalyDetector.linearRegressionFit([10, 9, 8, 7, 6, 5])
        #expect(fit != nil)
        guard let fit else { return }
        #expect(abs(fit.slope - (-1.0)) < 1e-9)
        #expect(abs(fit.rSquared - 1.0) < 1e-9)
    }

    @Test func constantSeriesHasZeroSlopeAndZeroRSquared() {
        // No variation means no information. Slope is exactly zero,
        // and we choose R² = 0 (the prior implementation's
        // convention) — anything else would misleadingly imply we
        // explained variance that isn't there.
        let fit = AnomalyDetector.linearRegressionFit([5, 5, 5, 5, 5, 5])
        #expect(fit != nil)
        guard let fit else { return }
        #expect(fit.slope == 0)
        #expect(fit.rSquared == 0)
    }

    @Test func noisySeriesProducesIntermediateRSquared() {
        // A real-ish leak trace: upward trend with noise. We don't pin
        // a specific R² value — we just check it lands strictly
        // between 0 and 1 (i.e. neither perfect nor noise-only).
        let noisyAscending: [Double] = [
            10, 11, 10, 12, 11, 13, 12, 14, 13, 15,
            14, 16, 15, 17, 16, 18, 17, 19, 18, 20
        ]
        let fit = AnomalyDetector.linearRegressionFit(noisyAscending)
        #expect(fit != nil)
        guard let fit else { return }
        #expect(fit.slope > 0.4 && fit.slope < 0.6)
        #expect(fit.rSquared > 0.5 && fit.rSquared < 1.0)
    }

    @Test func rSquaredClampedToValidRange() {
        // Sanity: regardless of input, R² must be a probability-like
        // value the UI/heuristics can rely on.
        let series: [Double] = (0..<50).map { _ in Double.random(in: 0...100) }
        let fit = AnomalyDetector.linearRegressionFit(series)
        #expect(fit != nil)
        guard let fit else { return }
        #expect(fit.rSquared >= 0 && fit.rSquared <= 1)
    }

    @Test func slopeMatchesAnalyticFormulaOnSimpleData() {
        // y = 2x + 3, no noise. Slope must be exactly 2, intercept
        // implied = 3, R² = 1.
        let xs = Array(0..<10)
        let ys = xs.map { 2.0 * Double($0) + 3.0 }
        let fit = AnomalyDetector.linearRegressionFit(ys)
        #expect(fit != nil)
        guard let fit else { return }
        #expect(abs(fit.slope - 2.0) < 1e-9)
        #expect(abs(fit.rSquared - 1.0) < 1e-9)
    }
}

struct AnomalyDetectorOscillationTests {

    @Test func emptySeriesScoresZero() {
        #expect(AnomalyDetector.oscillationScore([], minChangeMagnitude: 10) == 0)
    }

    @Test func singleSampleScoresZero() {
        #expect(AnomalyDetector.oscillationScore([42], minChangeMagnitude: 10) == 0)
    }

    @Test func steadySignalScoresZero() {
        let score = AnomalyDetector.oscillationScore(
            [50, 50, 50, 50, 50, 50, 50, 50],
            minChangeMagnitude: 10
        )
        #expect(score == 0)
    }

    @Test func smallFluctuationsBelowThresholdScoreZero() {
        // Jitter ≤ threshold must not count. Otherwise sensor noise
        // would flag every idle machine as "oscillating".
        let score = AnomalyDetector.oscillationScore(
            [50, 55, 48, 53, 47, 52, 49, 51],
            minChangeMagnitude: 10
        )
        #expect(score == 0)
    }

    @Test func singleBigJumpScoresZero() {
        // One direction change isn't oscillation — it's a transition.
        // Need at least one *reversal* (B→A direction flip).
        let score = AnomalyDetector.oscillationScore(
            [10, 10, 50, 50],
            minChangeMagnitude: 10
        )
        #expect(score == 0)
    }

    @Test func oneReversalScoresPointTwo() {
        // up, then down = 1 reversal. 1/5 = 0.2.
        let score = AnomalyDetector.oscillationScore(
            [10, 50, 10],
            minChangeMagnitude: 10
        )
        #expect(abs(score - 0.2) < 1e-9)
    }

    @Test func fivePlusReversalsSaturateAtOne() {
        // 10 alternations = 9 reversals, well past the cap.
        let alternating: [Double] = [
            10, 50, 10, 50, 10, 50, 10, 50, 10, 50,
            10, 50, 10, 50, 10, 50, 10, 50, 10, 50
        ]
        let score = AnomalyDetector.oscillationScore(
            alternating,
            minChangeMagnitude: 10
        )
        #expect(score == 1.0)
    }

    @Test func magnitudeThresholdIsHonoured() {
        // Same series scored against a larger threshold: every jump
        // is below the bar, so oscillation drops to zero.
        let series: [Double] = [10, 30, 10, 30, 10, 30]
        let scoreLow = AnomalyDetector.oscillationScore(series, minChangeMagnitude: 10)
        let scoreHigh = AnomalyDetector.oscillationScore(series, minChangeMagnitude: 25)
        #expect(scoreLow > 0)
        #expect(scoreHigh == 0)
    }
}
