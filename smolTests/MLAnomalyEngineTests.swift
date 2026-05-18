import Foundation
import Testing
@testable import smol

// MARK: - MLAnomalyEngine pure-logic tests
//
// The Core ML / Create ML paths require real training data and a
// trained model on disk, so we don't drive those here. The bits we
// cover are the pure decision logic that runs *around* the model:
// the anomaly-type priority rule, the confidence clamp that used
// to leak negative values, and the heuristic fallback that powers
// predictions before the user has collected ~16 minutes of data.

// MARK: - classifyAnomaly

struct MLAnomalyEngineClassifyTests {

    private typealias Engine = MLAnomalyEngine
    private typealias AnomalyType = MLAnomalyEngine.AnomalyPrediction.AnomalyType

    @Test func noFlagsReturnsNil() {
        #expect(Engine.classifyAnomaly(cpuAnomaly: false, memAnomaly: false, tempAnomaly: false) == nil)
    }

    @Test func onlyCpuFlagReturnsCpuSpike() {
        #expect(Engine.classifyAnomaly(cpuAnomaly: true, memAnomaly: false, tempAnomaly: false) == .cpuSpike)
    }

    @Test func onlyMemFlagReturnsMemoryLeak() {
        #expect(Engine.classifyAnomaly(cpuAnomaly: false, memAnomaly: true, tempAnomaly: false) == .memoryLeak)
    }

    @Test func onlyTempFlagReturnsThermalThrottling() {
        #expect(Engine.classifyAnomaly(cpuAnomaly: false, memAnomaly: false, tempAnomaly: true) == .thermalThrottling)
    }

    @Test func cpuAndMemFlagsReturnCombined() {
        // The prior implementation's sequential assignment would have
        // ended on `.memoryLeak` here before the combined fix kicked
        // in. The single-pass classifier returns `.combined` directly.
        #expect(Engine.classifyAnomaly(cpuAnomaly: true, memAnomaly: true, tempAnomaly: false) == .combined)
    }

    @Test func cpuAndTempFlagsReturnCombined() {
        #expect(Engine.classifyAnomaly(cpuAnomaly: true, memAnomaly: false, tempAnomaly: true) == .combined)
    }

    @Test func memAndTempFlagsReturnCombined() {
        #expect(Engine.classifyAnomaly(cpuAnomaly: false, memAnomaly: true, tempAnomaly: true) == .combined)
    }

    @Test func allThreeFlagsReturnCombined() {
        #expect(Engine.classifyAnomaly(cpuAnomaly: true, memAnomaly: true, tempAnomaly: true) == .combined)
    }
}

// MARK: - mlConfidence

struct MLAnomalyEngineConfidenceTests {

    private typealias Engine = MLAnomalyEngine

    @Test func nonAnomalyZeroDeviationIsFullConfidence() {
        // Perfect prediction, no anomaly → "we're sure nothing is
        // wrong". This is the high-confidence-clean-system case the
        // UI uses to render the green check.
        #expect(Engine.mlConfidence(maxDeviation: 0, isAnomaly: false) == 1.0)
    }

    @Test func nonAnomalyModerateDeviationGivesLowerConfidence() {
        // 30% deviation, no anomaly flag → 1 - 0.30 = 0.70.
        #expect(Engine.mlConfidence(maxDeviation: 0.30, isAnomaly: false) == 0.70)
    }

    @Test func nonAnomalyDeviationAboveOneClampsToZero() {
        // The bug we're fixing: model predicted 200%-of-something
        // when reality is normal. The pre-fix formula returned
        // `1 - 2.0 = -1.0` and that negative number flowed all the
        // way to `AIAnomaly.confidence` and the UI label.
        #expect(Engine.mlConfidence(maxDeviation: 2.0, isAnomaly: false) == 0)
        #expect(Engine.mlConfidence(maxDeviation: 5.0, isAnomaly: false) == 0)
    }

    @Test func anomalyZeroDeviationIsZeroConfidence() {
        // Zero deviation can't co-exist with isAnomaly=true in the
        // real flow, but if the threshold logic ever diverges from
        // the deviation values we don't want a confident "definitely
        // anomalous" verdict resting on nothing. 0 * 2 → 0.
        #expect(Engine.mlConfidence(maxDeviation: 0, isAnomaly: true) == 0)
    }

    @Test func anomalyHalfDeviationDoublesToOne() {
        // Deviation 0.5 → 1.0 (capped). Important boundary because
        // it's the smallest value that saturates the anomaly score.
        #expect(Engine.mlConfidence(maxDeviation: 0.5, isAnomaly: true) == 1.0)
    }

    @Test func anomalyBelowHalfDeviationIsScaled() {
        // Deviation 0.25 → 0.50. The "doubling" is meant to make
        // a small-but-clear anomaly land somewhere in the middle of
        // the confidence range rather than at the low end.
        #expect(Engine.mlConfidence(maxDeviation: 0.25, isAnomaly: true) == 0.50)
    }

    @Test func anomalyLargeDeviationStaysClampedAtOne() {
        // Already clamped via min() in the pre-fix code; pinning it
        // here so the boundary doesn't drift if someone re-orders
        // the clamps.
        #expect(Engine.mlConfidence(maxDeviation: 10.0, isAnomaly: true) == 1.0)
    }
}

// MARK: - heuristicPrediction

struct MLAnomalyEngineHeuristicTests {

    private typealias Engine = MLAnomalyEngine

    @Test func everythingNormalIsNotAnomalousWithHighConfidence() {
        // All metrics well below their thresholds — the heuristic
        // reports a clean system at 0.8 confidence.
        let p = Engine.heuristicPrediction(cpu: 30, memory: 40, temp: 50)
        #expect(p.isAnomaly == false)
        #expect(p.anomalyType == nil)
        #expect(p.confidence == 0.8)
    }

    @Test func cpuExactlyAtThresholdIsNotAnomaly() {
        // `cpu > 85` is strict — 85 itself does not trip the flag.
        // This boundary matters because users hovering at ~85% CPU
        // would otherwise see anomaly badges flicker.
        let p = Engine.heuristicPrediction(cpu: 85, memory: 0, temp: 0)
        #expect(p.isAnomaly == false)
    }

    @Test func cpuJustAboveThresholdIsCpuSpike() {
        let p = Engine.heuristicPrediction(cpu: 86, memory: 40, temp: 50)
        #expect(p.isAnomaly == true)
        #expect(p.anomalyType == .cpuSpike)
        #expect(p.confidence == 0.6)
    }

    @Test func memoryAboveThresholdIsMemoryLeak() {
        let p = Engine.heuristicPrediction(cpu: 30, memory: 81, temp: 50)
        #expect(p.isAnomaly == true)
        #expect(p.anomalyType == .memoryLeak)
    }

    @Test func temperatureAboveThresholdIsThermalThrottling() {
        let p = Engine.heuristicPrediction(cpu: 30, memory: 40, temp: 91)
        #expect(p.isAnomaly == true)
        #expect(p.anomalyType == .thermalThrottling)
    }

    @Test func twoSignalsCollapseToCombined() {
        // CPU + memory both crossing — the priority rule used to be
        // a sequential overwrite (later one wins) plus a count-based
        // `.combined` override. We pin the user-facing outcome here.
        let p = Engine.heuristicPrediction(cpu: 90, memory: 85, temp: 50)
        #expect(p.isAnomaly == true)
        #expect(p.anomalyType == .combined)
    }

    @Test func allThreeSignalsCollapseToCombined() {
        let p = Engine.heuristicPrediction(cpu: 90, memory: 85, temp: 95)
        #expect(p.anomalyType == .combined)
    }

    @Test func predictedValuesEchoInputsInHeuristicMode() {
        // The heuristic has no model, so it returns the input
        // values as the "prediction". Downstream code uses these to
        // build expected-range badges and a regression that swapped
        // these to zero (or to the average) would silently change
        // the UI numbers.
        let p = Engine.heuristicPrediction(cpu: 55, memory: 60, temp: 70)
        #expect(p.predictedCPU == 55)
        #expect(p.predictedMemory == 60)
        #expect(p.predictedTemp == 70)
    }
}
