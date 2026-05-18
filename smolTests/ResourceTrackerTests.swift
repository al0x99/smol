import Foundation
import Testing
@testable import smol

// MARK: - ResourceTracker pure-logic tests
//
// We don't drive the live sampling timer here — that path needs
// real wall-clock time and is covered by integration usage in
// `SmartAdvisor` / `LocalLLMEngine`. Instead, we pin the parts
// that are timestamp-independent: the impact-bucket rule, the
// LLM-cost lookup table, and the formatter's sign handling for
// `memoryDelta`.

// MARK: - ImpactLevel rule

struct ResourceCostImpactLevelTests {

    private typealias Cost = ResourceTracker.ResourceCost

    @Test func wellUnderBothThresholdsIsLow() {
        #expect(Cost.impactLevel(avgCPU: 0, estimatedEnergy: 0) == .low)
        #expect(Cost.impactLevel(avgCPU: 10, estimatedEnergy: 0.1) == .low)
    }

    @Test func justBelowBothThresholdsIsLow() {
        // 29.9% CPU and 0.49 mWh — both strictly under the low
        // bucket's bounds. Strict `<` is what makes the boundary
        // belong to the next bucket up; this case stays in low.
        #expect(Cost.impactLevel(avgCPU: 29.9, estimatedEnergy: 0.49) == .low)
    }

    @Test func cpuExactlyAtLowBoundaryFallsToMedium() {
        // The rule uses `avgCPU < 30`, so 30 itself is not "low".
        // Energy is still tiny so it lands in the medium bucket
        // (avgCPU < 70 && energy < 2.0).
        #expect(Cost.impactLevel(avgCPU: 30, estimatedEnergy: 0.1) == .medium)
    }

    @Test func energyExactlyAtLowBoundaryFallsToMedium() {
        // Mirror of the above for the energy axis.
        #expect(Cost.impactLevel(avgCPU: 10, estimatedEnergy: 0.5) == .medium)
    }

    @Test func midRangeIsMedium() {
        #expect(Cost.impactLevel(avgCPU: 50, estimatedEnergy: 1.0) == .medium)
        #expect(Cost.impactLevel(avgCPU: 65, estimatedEnergy: 1.5) == .medium)
    }

    @Test func cpuExactlyAtMediumBoundaryFallsToHigh() {
        // `avgCPU < 70` excludes 70 from medium → high.
        #expect(Cost.impactLevel(avgCPU: 70, estimatedEnergy: 0.1) == .high)
    }

    @Test func energyExactlyAtMediumBoundaryFallsToHigh() {
        // `estimatedEnergy < 2.0` excludes 2.0 from medium → high.
        #expect(Cost.impactLevel(avgCPU: 10, estimatedEnergy: 2.0) == .high)
    }

    @Test func wellAboveBothThresholdsIsHigh() {
        #expect(Cost.impactLevel(avgCPU: 95, estimatedEnergy: 5.0) == .high)
        #expect(Cost.impactLevel(avgCPU: 100, estimatedEnergy: 100) == .high)
    }

    @Test func highCpuLowEnergyIsHigh() {
        // CPU above medium bound — no way back to medium even if
        // energy is negligible. This guards against a hypothetical
        // re-ordering of the conditions that would let high CPU
        // sneak through the energy check.
        #expect(Cost.impactLevel(avgCPU: 90, estimatedEnergy: 0.0) == .high)
    }

    @Test func lowCpuHighEnergyIsHigh() {
        // Symmetric: energy alone past 2.0 escalates to high.
        #expect(Cost.impactLevel(avgCPU: 5, estimatedEnergy: 10.0) == .high)
    }

    @Test func instanceComputedPropertyMatchesStatic() {
        // Sanity: the stored-value computed property must produce
        // the same bucket as the pure rule, for the same inputs.
        let cost = ResourceTracker.ResourceCost(
            duration: 1.0,
            avgCPU: 50,
            peakCPU: 70,
            memoryDelta: 0,
            peakMemory: 0,
            estimatedEnergy: 1.0,
            tokenCount: nil
        )
        #expect(cost.impactLevel == Cost.impactLevel(avgCPU: 50, estimatedEnergy: 1.0))
        #expect(cost.impactLevel == .medium)
    }
}

// MARK: - LLM cost estimator

struct ResourceTrackerLLMCostTests {

    @Test func tinyModelHasNoWarning() {
        let estimate = ResourceTracker.estimateLLMCost(inputTokens: 50, modelSize: .tiny)
        #expect(estimate.warning == nil)
        #expect(estimate.estimatedCPU == 40)
        #expect(estimate.estimatedMemoryMB == 800)
    }

    @Test func smallModelHasNoWarning() {
        let estimate = ResourceTracker.estimateLLMCost(inputTokens: 100, modelSize: .small)
        #expect(estimate.warning == nil)
        #expect(estimate.estimatedCPU == 60)
        #expect(estimate.estimatedMemoryMB == 2000)
    }

    @Test func mediumModelGetsSlowdownWarning() {
        let estimate = ResourceTracker.estimateLLMCost(inputTokens: 100, modelSize: .medium)
        // The exact wording lives in the source; we only pin that
        // a warning fires and mentions slowdown so a UI that
        // surfaces it doesn't show an empty banner.
        #expect(estimate.warning != nil)
        #expect(estimate.warning?.contains("slow") == true)
        #expect(estimate.estimatedCPU == 80)
        #expect(estimate.estimatedMemoryMB == 4500)
    }

    @Test func largeModelGetsBatteryWarning() {
        let estimate = ResourceTracker.estimateLLMCost(inputTokens: 100, modelSize: .large)
        #expect(estimate.warning != nil)
        #expect(estimate.warning?.contains("battery") == true)
        #expect(estimate.estimatedCPU == 95)
        #expect(estimate.estimatedMemoryMB == 9000)
    }

    @Test func durationScalesWithInputTokens() {
        // Output is modeled as 2× input, so total tokens = 3×
        // input. Doubling input must double the projected
        // duration for the same model.
        let small = ResourceTracker.estimateLLMCost(inputTokens: 30, modelSize: .tiny)
        let bigger = ResourceTracker.estimateLLMCost(inputTokens: 60, modelSize: .tiny)
        #expect(bigger.estimatedDuration == small.estimatedDuration * 2)
    }

    @Test func biggerModelIsSlowerForSameInput() {
        // The tokens-per-second table is strictly decreasing as
        // model size grows, so duration must rise monotonically.
        let tiny   = ResourceTracker.estimateLLMCost(inputTokens: 50, modelSize: .tiny)
        let small  = ResourceTracker.estimateLLMCost(inputTokens: 50, modelSize: .small)
        let medium = ResourceTracker.estimateLLMCost(inputTokens: 50, modelSize: .medium)
        let large  = ResourceTracker.estimateLLMCost(inputTokens: 50, modelSize: .large)
        #expect(tiny.estimatedDuration < small.estimatedDuration)
        #expect(small.estimatedDuration < medium.estimatedDuration)
        #expect(medium.estimatedDuration < large.estimatedDuration)
    }

    @Test func tinyModelKnownArithmetic() {
        // Spot-check the formula end-to-end so a stray refactor
        // can't silently drift the numbers shown in the UI:
        //   totalTokens  = 100 * 3 = 300
        //   duration     = 300 / 30 = 10 s
        //   powerWatts   = (40 / 100) * 15 = 6 W
        //   energyMWh    = 6 * 10 / 3600 * 1000 ≈ 16.667
        let estimate = ResourceTracker.estimateLLMCost(inputTokens: 100, modelSize: .tiny)
        #expect(estimate.estimatedDuration == 10)
        // Use a tolerance — the math is fine but printed in mWh,
        // and we don't want a one-ULP drift to break this test.
        let expectedEnergy = 6.0 * 10.0 / 3600.0 * 1000.0
        #expect(abs(estimate.estimatedEnergyMWh - expectedEnergy) < 0.001)
    }

    @Test func zeroInputTokensProducesZeroDuration() {
        // Edge case: empty prompt. We don't want a UI surprise
        // like "~NaN seconds" or a non-zero estimate for nothing.
        let estimate = ResourceTracker.estimateLLMCost(inputTokens: 0, modelSize: .tiny)
        #expect(estimate.estimatedDuration == 0)
        #expect(estimate.estimatedEnergyMWh == 0)
    }
}

// MARK: - ResourceCost formatting

struct ResourceCostFormattingTests {

    private func cost(memoryDelta: Int64, tokenCount: Int? = nil) -> ResourceTracker.ResourceCost {
        ResourceTracker.ResourceCost(
            duration: 1.0,
            avgCPU: 0,
            peakCPU: 0,
            memoryDelta: memoryDelta,
            peakMemory: 0,
            estimatedEnergy: 0,
            tokenCount: tokenCount
        )
    }

    @Test func positiveMemoryDeltaUsesPlusSign() {
        let text = cost(memoryDelta: 1_048_576).description
        #expect(text.contains("RAM: +1.0 MB"))
    }

    @Test func negativeMemoryDeltaUsesMinusSign() {
        // The formatter uses `abs(memoryDelta)` for the magnitude
        // and chooses the sign separately — guarding against the
        // double-minus bug ("RAM: --1.0 MB") that comes from
        // letting `String(format:)` print a negative number with
        // a manual `-` prefix.
        let text = cost(memoryDelta: -2_097_152).description
        #expect(text.contains("RAM: -2.0 MB"))
        #expect(!text.contains("--"))
    }

    @Test func zeroMemoryDeltaShowsPlusZero() {
        // The current contract: `memoryDelta >= 0` → "+". Zero is
        // not negative so it gets `+0.0 MB`. Pin this rather than
        // assert it's "-0.0" — if someone flips the comparison
        // the test catches it.
        let text = cost(memoryDelta: 0).description
        #expect(text.contains("RAM: +0.0 MB"))
    }

    @Test func tokenCountAppearsOnlyWhenSet() {
        let withTokens = cost(memoryDelta: 0, tokenCount: 120).description
        let withoutTokens = cost(memoryDelta: 0, tokenCount: nil).description
        #expect(withTokens.contains("120 tokens"))
        #expect(!withoutTokens.contains("tokens"))
    }

    @Test func userFriendlyDescriptionReflectsImpact() {
        // High-impact cost — UI shows the red marker and the
        // textual label, so a UI snapshot that depends on either
        // string fragment doesn't silently drift.
        let highCost = ResourceTracker.ResourceCost(
            duration: 5.0,
            avgCPU: 95,
            peakCPU: 100,
            memoryDelta: 0,
            peakMemory: 0,
            estimatedEnergy: 50,
            tokenCount: nil
        )
        let text = highCost.userFriendlyDescription
        #expect(text.contains("High impact"))
        #expect(text.contains("🔴"))
    }
}
