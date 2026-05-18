import Foundation
import Testing
@testable import smol

// MARK: - MemoryMonitor.pressurePercent
//
// This formula drives the LOW/MEDIUM/HIGH chip in the dashboard and is
// the input to `SystemMonitor.calculateHealth()`'s memory-pressure
// rules. A regression here misclassifies a healthy machine as warning
// or vice versa. The old formula added `min(50, stats.pageouts /
// 1000)` to the compression ratio — but `stats.pageouts` is cumulative
// since boot, so on any machine with a few days of uptime that term
// saturated to 50 and the score was pinned at ≥50% (which then tripped
// `calculateHealth`'s `> 50` warning). The tests below pin the new,
// honest formula and the boundaries it has to hit.

struct MemoryMonitorPressureTests {

    @Test func zeroTotalReturnsZero() {
        // Guard against divide-by-zero if host_statistics64 returns
        // an empty snapshot (e.g. straight after boot, theoretically).
        #expect(MemoryMonitor.pressurePercent(compressedPages: 0, totalPages: 0) == 0)
    }

    @Test func nothingCompressedIsZero() {
        #expect(MemoryMonitor.pressurePercent(compressedPages: 0, totalPages: 1_000_000) == 0)
    }

    @Test func fullyCompressedIsHundred() {
        // Degenerate, but the formula has to clamp.
        let pct = MemoryMonitor.pressurePercent(compressedPages: 1_000_000, totalPages: 1_000_000)
        #expect(abs(pct - 100) < 0.0001)
    }

    @Test func halfCompressedIsFifty() {
        // Boundary: matches the MemoryInfo.pressureLevel `< 50` LOW
        // cutoff — exactly 50% compression should map to MEDIUM.
        let pct = MemoryMonitor.pressurePercent(compressedPages: 500_000, totalPages: 1_000_000)
        #expect(abs(pct - 50) < 0.0001)
    }

    @Test func tenPercentCompressedStaysLow() {
        // A healthy long-uptime Apple Silicon machine sits around
        // 10–20% compression. The score must stay below the `> 50`
        // warning floor so `SystemMonitor.calculateHealth` reports
        // `.healthy`. (This is the exact case the old `pageouts/1000`
        // term broke — it would have added 50 here on any machine that
        // had been up more than a few hours.)
        let pct = MemoryMonitor.pressurePercent(compressedPages: 100_000, totalPages: 1_000_000)
        #expect(pct < 50, "10% compression must not trip the medium-pressure warning")
        #expect(abs(pct - 10) < 0.0001)
    }

    @Test func overSubscribedClampsToHundred() {
        // Shouldn't happen in practice (compressedPages is a subset of
        // totalPages by definition) but a defensive clamp prevents an
        // out-of-range value from poisoning the health calculation.
        let pct = MemoryMonitor.pressurePercent(compressedPages: 2_000_000, totalPages: 1_000_000)
        #expect(pct == 100)
    }

    @Test func neverExceedsHundred() {
        let pct = MemoryMonitor.pressurePercent(compressedPages: .max, totalPages: 1)
        #expect(pct == 100)
    }
}
