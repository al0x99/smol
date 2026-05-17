import Foundation
import Testing
@testable import smol

// MARK: - FanInfo.rpmPercent
//
// The fan rows in the dashboard render this percentage as a bar and the
// menu-bar widget reads it via VoiceOver. A regression here is silent —
// the bar simply shows the wrong fill — so the edge cases are worth
// pinning down explicitly. None of these constructors touch IOKit or the
// XPC helper because FanInfo is a plain struct nested in FanMonitor.

struct FanInfoTests {

    private func fan(current: Int, min: Int = 1200, max: Int = 6000) -> FanMonitor.FanInfo {
        FanMonitor.FanInfo(id: 0,
                           name: "Test",
                           currentRPM: current,
                           minRPM: min,
                           maxRPM: max,
                           targetRPM: current)
    }

    @Test func atMinReportsZero() {
        #expect(fan(current: 1200).rpmPercent == 0)
    }

    @Test func atMaxReportsHundred() {
        #expect(fan(current: 6000).rpmPercent == 100)
    }

    @Test func midRangeIsProportional() {
        let pct = fan(current: 3600).rpmPercent
        #expect(abs(pct - 50.0) < 0.0001)
    }

    @Test func belowMinClampsToZero() {
        // Parked-fan reading: currentRPM=0 with a positive minRPM.
        #expect(fan(current: 0).rpmPercent == 0)
    }

    @Test func aboveMaxClampsToHundred() {
        // SMC F*Ac can briefly overshoot F*Mx during a wake transition.
        #expect(fan(current: 7000).rpmPercent == 100)
    }

    @Test func degenerateRangeReturnsZero() {
        // If SMC returns garbage (min >= max) we must not divide by zero
        // or produce NaN — the bar would render as full or invalid.
        #expect(fan(current: 1500, min: 5000, max: 5000).rpmPercent == 0)
        #expect(fan(current: 1500, min: 5000, max: 4000).rpmPercent == 0)
    }

    @Test func percentNeverGoesNegative() {
        #expect(fan(current: -100, min: 0, max: 6000).rpmPercent == 0)
    }
}

// MARK: - SystemMonitor.TemperatureTrend
//
// The trend symbol drives the arrow shown beside the temperature reading.
// Pure switch — pin it so a refactor can't silently swap the glyphs.

@MainActor
struct TemperatureTrendTests {

    @Test func risingSymbol() {
        #expect(SystemMonitor.TemperatureTrend.rising.symbol == "↑")
    }

    @Test func fallingSymbol() {
        #expect(SystemMonitor.TemperatureTrend.falling.symbol == "↓")
    }

    @Test func stableSymbol() {
        #expect(SystemMonitor.TemperatureTrend.stable.symbol == "→")
    }
}
