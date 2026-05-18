import Foundation
import Testing
@testable import smol

// MARK: - CPUMonitor.idlePercent
//
// `getIdlePercent()` is what drives the menu-bar CPU number and the
// `cpuIdlePercent` published property that feeds into
// `SystemMonitor.calculateHealth`'s "hot at idle" rule. The actual
// snapshot comes from `host_processor_info` (Mach), but the bit that
// turns two snapshots into a percentage is pure arithmetic — we test
// that here without standing up a kernel call.
//
// Inputs are *cumulative* tick counters (idle and total across all
// cores). The function returns `(currentIdle - previousIdle) /
// (currentTotal - previousTotal) * 100`, clamped to [0, 100], with a
// graceful fallback when the deltas are zero (the first call after
// launch).

struct CPUMonitorIdleTests {

    private func pct(idle: UInt64, total: UInt64,
                     prevIdle: UInt64 = 0, prevTotal: UInt64 = 0) -> Double {
        CPUMonitor.idlePercent(
            currentIdle: idle,
            currentTotal: total,
            previousIdle: prevIdle,
            previousTotal: prevTotal
        )
    }

    @Test func zeroTotalAndZeroPreviousReturnsHundred() {
        // Brand-new process, brand-new Mach: no ticks have elapsed
        // ever. Defaulting to "idle" is safer than dividing by zero.
        #expect(pct(idle: 0, total: 0) == 100)
    }

    @Test func firstCallFallsBackToLifetimeAverage() {
        // First poll after launch: previous counters are 0, so the
        // formula degenerates to `currentIdle / currentTotal`. That's
        // the lifetime average — one tick of "off" reading before the
        // delta-based values stabilise.
        let result = pct(idle: 800, total: 1000)
        #expect(abs(result - 80) < 0.0001)
    }

    @Test func deltaMode_halfIdleIsFifty() {
        // Between samples the system did 200 idle ticks out of 400
        // total ticks — exactly 50%.
        let result = pct(idle: 1200, total: 1400, prevIdle: 1000, prevTotal: 1000)
        #expect(abs(result - 50) < 0.0001)
    }

    @Test func deltaMode_fullIdleIsHundred() {
        let result = pct(idle: 2000, total: 2000, prevIdle: 1000, prevTotal: 1000)
        #expect(result == 100)
    }

    @Test func deltaMode_fullBusyIsZero() {
        // 0 idle ticks but 1000 total ticks elapsed: CPU was 100% busy.
        let result = pct(idle: 1000, total: 2000, prevIdle: 1000, prevTotal: 1000)
        #expect(result == 0)
    }

    @Test func idleDeltaExceedingTotalDeltaClampsToHundred() {
        // Aggressive power-state transitions can briefly push the
        // reported idle delta above the total delta. The clamp keeps
        // the menu bar from showing 110%.
        let result = pct(idle: 2000, total: 1500, prevIdle: 1000, prevTotal: 1000)
        #expect(result == 100)
    }

    @Test func counterResetWrapsCleanlyToClampedValue() {
        // If the system goes through a state that makes previous > current
        // (counter reset on sleep/resume, or test-injected weirdness),
        // the `&-` wrap in the function combined with the clamp gives
        // us a defined value in [0, 100] instead of a trap.
        let result = pct(idle: 100, total: 200, prevIdle: 1000, prevTotal: 1000)
        // No crash, value is in range — that's the whole contract.
        #expect(result >= 0 && result <= 100)
    }

    @Test func noChangeBetweenSamplesFallsBackToLifetime() {
        // Two identical reads in a row (totalDelta == 0). Function
        // must not divide by zero; falls back to lifetime average of
        // the current reading.
        let result = pct(idle: 800, total: 1000, prevIdle: 800, prevTotal: 1000)
        #expect(abs(result - 80) < 0.0001)
    }
}
