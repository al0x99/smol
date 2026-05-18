import Foundation
import Testing
@testable import smol

// MARK: - SystemMonitor.calculateHealth
//
// The threshold ladder below drives the menu-bar widget colour and the
// VoiceOver summary. A regression here means the icon goes green while
// the machine is actually swapping, or shows critical-red while the
// machine is fine — both are user-visible bugs. The rules are evaluated
// top-to-bottom and the first match wins, so the tests must pin both
// individual rules AND the ordering between them.
//
// `calculateHealth` is a pure static function that takes its inputs
// explicitly, so none of these tests have to stand up a real
// `SystemMonitor` (which would also start its 2-second polling Timer).

@MainActor
struct SystemMonitorHealthTests {

    private func memory(pressure: Double = 0, swap: UInt64 = 0) -> MemoryInfo {
        MemoryInfo(used: 0, total: 16_000_000_000, pressure: pressure, swapUsed: swap)
    }

    private func evaluate(
        memory: MemoryInfo? = nil,
        temperature: Double = 50,
        cpuIdle: Double = 90,
        suspicious: Int = 0
    ) -> SystemHealth {
        SystemMonitor.calculateHealth(
            memoryInfo: memory ?? self.memory(),
            temperature: temperature,
            cpuIdlePercent: cpuIdle,
            suspiciousProcessCount: suspicious
        )
    }

    // MARK: critical rules

    @Test func heavySwapIsCritical() {
        let result = evaluate(memory: memory(swap: 2_000_000_000))
        if case let .critical(reason) = result {
            #expect(reason.hasPrefix("Heavy swap"))
        } else {
            Issue.record("expected .critical for 2 GB swap, got \(result)")
        }
    }

    @Test func swapAtOneGBExactlyIsWarningNotCritical() {
        // Boundary: the critical rule is "> 1 GB", so exactly 1 GB must
        // fall through to the "any swap" warning rather than tripping
        // critical.
        let result = evaluate(memory: memory(swap: 1_000_000_000))
        #expect(result == .warning(reason: "Swap in use"))
    }

    @Test func memoryPressureAt81IsCritical() {
        let result = evaluate(memory: memory(pressure: 81))
        if case let .critical(reason) = result {
            #expect(reason.hasPrefix("Memory pressure critical"))
        } else {
            Issue.record("expected .critical for pressure 81%, got \(result)")
        }
    }

    @Test func memoryPressureAt80IsWarningNotCritical() {
        // Boundary: "> 80" — exactly 80 must be warning ("> 50") only.
        let result = evaluate(memory: memory(pressure: 80))
        #expect(result == .warning(reason: "Memory pressure medium"))
    }

    @Test func hotAtIdleIsCritical() {
        let result = evaluate(temperature: 96, cpuIdle: 75)
        if case let .critical(reason) = result {
            #expect(reason.hasPrefix("Hot at idle"))
        } else {
            Issue.record("expected .critical for 96°C @ 75% idle, got \(result)")
        }
    }

    @Test func hotButNotIdleIsNotCritical() {
        // CPU is busy (low idle) so a high temperature is expected work,
        // not an idle anomaly — must NOT trip the "Hot at idle" critical.
        // 100°C with 30% idle falls through to "Elevated temperature"
        // warning (>80°C, >50% idle is false here so this becomes
        // .healthy — pin both possibilities).
        let busy = evaluate(temperature: 100, cpuIdle: 30)
        #expect(busy == .healthy, "busy CPU at high temp should not be critical")
    }

    // MARK: warning rules

    @Test func anySwapIsWarning() {
        let result = evaluate(memory: memory(swap: 1))
        #expect(result == .warning(reason: "Swap in use"))
    }

    @Test func mediumPressureIsWarning() {
        let result = evaluate(memory: memory(pressure: 60))
        #expect(result == .warning(reason: "Memory pressure medium"))
    }

    @Test func suspiciousProcessSingularGrammar() {
        let result = evaluate(suspicious: 1)
        #expect(result == .warning(reason: "1 suspicious process"))
    }

    @Test func suspiciousProcessPluralGrammar() {
        let result = evaluate(suspicious: 3)
        #expect(result == .warning(reason: "3 suspicious processes"))
    }

    @Test func elevatedTemperatureIsWarning() {
        let result = evaluate(temperature: 85, cpuIdle: 60)
        #expect(result == .warning(reason: "Elevated temperature"))
    }

    @Test func temperatureBoundaryAt80IsHealthy() {
        // "> 80" — exactly 80 must not trip the warning.
        let result = evaluate(temperature: 80, cpuIdle: 60)
        #expect(result == .healthy)
    }

    // MARK: priority ordering

    @Test func swapBeatsMemoryPressure() {
        // Heavy swap (> 1 GB) is critical and must win over critical
        // pressure — the message must mention swap, not pressure.
        let result = evaluate(memory: memory(pressure: 95, swap: 2_000_000_000))
        if case let .critical(reason) = result {
            #expect(reason.hasPrefix("Heavy swap"))
        } else {
            Issue.record("expected swap-critical to win, got \(result)")
        }
    }

    @Test func criticalMemoryBeatsHotAtIdle() {
        let result = evaluate(memory: memory(pressure: 95), temperature: 96, cpuIdle: 75)
        if case let .critical(reason) = result {
            #expect(reason.hasPrefix("Memory pressure critical"))
        } else {
            Issue.record("expected memory-critical to win, got \(result)")
        }
    }

    @Test func swapWarningBeatsPressureWarning() {
        // With swap > 0 the "Swap in use" rule fires before the medium-
        // pressure rule, so the displayed message must be the swap one.
        let result = evaluate(memory: memory(pressure: 60, swap: 1))
        #expect(result == .warning(reason: "Swap in use"))
    }

    @Test func pressureWarningBeatsSuspiciousProcess() {
        let result = evaluate(memory: memory(pressure: 60), suspicious: 5)
        #expect(result == .warning(reason: "Memory pressure medium"))
    }

    @Test func suspiciousBeatsElevatedTemperature() {
        let result = evaluate(temperature: 85, cpuIdle: 60, suspicious: 1)
        #expect(result == .warning(reason: "1 suspicious process"))
    }

    // MARK: healthy base case

    @Test func healthyWhenAllNormal() {
        #expect(evaluate() == .healthy)
    }
}
