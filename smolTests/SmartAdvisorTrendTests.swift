import Foundation
import Testing
@testable import smol

// MARK: - SmartAdvisor.trend
//
// `SmartAdvisor` uses this windowed delta to decide whether to add
// "CPU rising", "Temperature rising rapidly", or "Possible memory
// leak" cards to the advice panel. The math is timestamp-sensitive
// (the live `calculateTrend` uses `Date()` internally), so the pure
// `static trend(in:windowMinutes:now:)` is the part we cover — it
// takes `now` explicitly and is otherwise identical to the live
// path.

struct SmartAdvisorTrendTests {

    private func point(_ secondsAgo: TimeInterval, value: Double, now: Date) -> AIDataPoint {
        AIDataPoint(timestamp: now.addingTimeInterval(-secondsAgo), value: value)
    }

    @Test func emptyHistoryReturnsNil() {
        #expect(SmartAdvisor.trend(in: [], windowMinutes: 2, now: Date()) == nil)
    }

    @Test func singleSampleReturnsNil() {
        // A trend needs two points by definition. The live caller's
        // `if let trend = ...` pattern means returning nil here is
        // equivalent to "no signal" — neither suppresses nor fires
        // advice cards.
        let now = Date()
        let only = [point(0, value: 50, now: now)]
        #expect(SmartAdvisor.trend(in: only, windowMinutes: 2, now: now) == nil)
    }

    @Test func normalDeltaIsLastMinusFirstInWindow() {
        // "Memory pressure rose from 30 → 45" over the window.
        // The unit is *value units* (percentage points or °C),
        // not a percentage of the starting value — that confusion
        // was baked into the prior doc-comment.
        let now = Date()
        let history = [
            point(120, value: 30, now: now),
            point(60,  value: 38, now: now),
            point(0,   value: 45, now: now)
        ]
        let result = SmartAdvisor.trend(in: history, windowMinutes: 2, now: now)
        #expect(result == 15)
    }

    @Test func negativeTrendOnDescendingSeries() {
        // Temperature falling — the live caller filters with
        // `trend > 10` so this should not surface as a warning,
        // but the function itself must return the negative.
        let now = Date()
        let history = [
            point(60, value: 80, now: now),
            point(30, value: 75, now: now),
            point(0,  value: 60, now: now)
        ]
        let result = SmartAdvisor.trend(in: history, windowMinutes: 1, now: now)
        #expect(result == -20)
    }

    @Test func samplesOlderThanWindowAreExcluded() {
        // Two samples 5+ minutes old, one fresh — only the fresh one
        // falls in the 1-minute window, so we don't have a pair.
        let now = Date()
        let history = [
            point(400, value: 10, now: now),
            point(300, value: 20, now: now),
            point(0,   value: 90, now: now)
        ]
        let result = SmartAdvisor.trend(in: history, windowMinutes: 1, now: now)
        #expect(result == nil)
    }

    @Test func boundaryAtWindowStartIsIncluded() {
        // A sample taken *exactly* `windowMinutes` ago must be inside
        // the window (`>=` rather than `>`). This pins that contract.
        let now = Date()
        let history = [
            point(120, value: 40, now: now),  // exactly at the edge
            point(0,   value: 60, now: now)
        ]
        let result = SmartAdvisor.trend(in: history, windowMinutes: 2, now: now)
        #expect(result == 20)
    }

    @Test func allSamplesOutsideWindowReturnsNil() {
        // Every sample predates the window. Without something inside
        // we have no comparable pair.
        let now = Date()
        let history = [
            point(600, value: 10, now: now),
            point(400, value: 20, now: now),
            point(300, value: 30, now: now)
        ]
        let result = SmartAdvisor.trend(in: history, windowMinutes: 1, now: now)
        #expect(result == nil)
    }

    @Test func flatSeriesInWindowReturnsZero() {
        // Pressure held constant — slope is genuinely zero, not nil.
        // The "no signal" semantics belong to nil; "we measured and
        // it didn't move" is 0.
        let now = Date()
        let history = [
            point(60, value: 55, now: now),
            point(30, value: 55, now: now),
            point(0,  value: 55, now: now)
        ]
        let result = SmartAdvisor.trend(in: history, windowMinutes: 1, now: now)
        #expect(result == 0)
    }
}
