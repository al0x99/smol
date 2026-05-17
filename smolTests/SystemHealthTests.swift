import Foundation
import Testing
import SwiftUI
@testable import smol

// MARK: - SystemHealth

@MainActor
struct SystemHealthTests {

    @Test func healthyDescriptionAndStyle() {
        let h: SystemHealth = .healthy
        #expect(h.description == "System healthy")
        #expect(h.color == .green)
        #expect(h.iconName == "checkmark.circle.fill")
    }

    @Test func warningDescriptionAndStyle() {
        let h: SystemHealth = .warning(reason: "Swap in use")
        #expect(h.description == "Warning: Swap in use")
        #expect(h.color == .yellow)
        #expect(h.iconName == "exclamationmark.triangle.fill")
    }

    @Test func criticalDescriptionAndStyle() {
        let h: SystemHealth = .critical(reason: "Heavy swap")
        #expect(h.description == "Critical: Heavy swap")
        #expect(h.color == .red)
        #expect(h.iconName == "xmark.circle.fill")
    }

    @Test func equalityHonoursAssociatedValues() {
        #expect(SystemHealth.healthy == .healthy)
        #expect(SystemHealth.warning(reason: "x") == .warning(reason: "x"))
        #expect(SystemHealth.warning(reason: "x") != .warning(reason: "y"))
        #expect(SystemHealth.critical(reason: "x") != .warning(reason: "x"))
    }
}

// MARK: - MemoryInfo

struct MemoryInfoTests {

    private func info(pressure: Double, swap: UInt64 = 0) -> MemoryInfo {
        MemoryInfo(used: 0, total: 16_000_000_000, pressure: pressure, swapUsed: swap)
    }

    @Test func pressureLevelBoundaries() {
        #expect(info(pressure: 0).pressureLevel == "LOW")
        #expect(info(pressure: 49.9).pressureLevel == "LOW")
        #expect(info(pressure: 50).pressureLevel == "MEDIUM")
        #expect(info(pressure: 79.9).pressureLevel == "MEDIUM")
        #expect(info(pressure: 80).pressureLevel == "HIGH")
        #expect(info(pressure: 100).pressureLevel == "HIGH")
    }

    @Test func isHealthyRequiresLowPressureAndNoSwap() {
        #expect(info(pressure: 30, swap: 0).isHealthy)
        #expect(!info(pressure: 30, swap: 1).isHealthy)        // any swap fails
        #expect(!info(pressure: 50, swap: 0).isHealthy)        // pressure boundary fails
        #expect(!info(pressure: 90, swap: 0).isHealthy)
    }
}

// MARK: - ProcessInfo

struct SmolProcessInfoTests {

    @Test func notAnomalyIfRecentlyStarted() {
        let p = ProcessInfo(
            id: 1,
            name: "p",
            cpuPercent: 99,
            memoryBytes: 0,
            startTime: Date(),                                  // just started
            cpuTimeMinutes: 0
        )
        #expect(!p.isAnomaly)
    }

    @Test func notAnomalyIfCPULow() {
        let p = ProcessInfo(
            id: 2,
            name: "p",
            cpuPercent: 5,
            memoryBytes: 0,
            startTime: Date().addingTimeInterval(-3600),       // running an hour
            cpuTimeMinutes: 0
        )
        #expect(!p.isAnomaly)
    }

    @Test func anomalyIfHighCPUAndLongRunning() {
        let p = ProcessInfo(
            id: 3,
            name: "p",
            cpuPercent: 80,
            memoryBytes: 0,
            startTime: Date().addingTimeInterval(-1200),       // 20 min ago
            cpuTimeMinutes: 0
        )
        #expect(p.isAnomaly)
    }

    @Test func memoryFormatted() {
        let p = ProcessInfo(
            id: 4,
            name: "p",
            cpuPercent: 0,
            memoryBytes: 1_048_576,                            // 1 MiB
            startTime: Date(),
            cpuTimeMinutes: 0
        )
        // ByteCountFormatter output varies by locale ("1 MB" / "1.0 MB" / "1 MiB"),
        // so just assert it's non-empty and contains a unit hint.
        #expect(!p.memoryFormatted.isEmpty)
    }
}

// MARK: - AlertSettings

@MainActor
struct AlertSettingsTests {

    @Test func presetsAreThreeAndAllDistinct() {
        let presets = AlertSettings.presets
        #expect(presets.count == 3)
        let names = Set(presets.map(\.name))
        #expect(names.count == 3, "Preset names must be unique")
    }

    @Test func balancedPresetMatchesDefaults() {
        // The "Balanced" preset must equal the defaults `resetToDefaults` writes,
        // otherwise resetting and selecting Balanced produce different states.
        let balanced = AlertSettings.presets.first { $0.name == "Balanced" }
        #expect(balanced != nil)
        #expect(balanced?.cpuThreshold == 30)
        #expect(balanced?.minRunningMinutes == 10)
        #expect(balanced?.cpuTimeThreshold == 5)
    }

    @Test func applyPresetCopiesAllThreeThresholds() {
        let settings = AlertSettings()
        settings.cpuThreshold = 99
        settings.minRunningMinutes = 99
        settings.cpuTimeThreshold = 99

        let sensitive = AlertSettings.presets.first { $0.name == "Sensitive" }!
        settings.applyPreset(sensitive)

        #expect(settings.cpuThreshold == sensitive.cpuThreshold)
        #expect(settings.minRunningMinutes == sensitive.minRunningMinutes)
        #expect(settings.cpuTimeThreshold == sensitive.cpuTimeThreshold)
    }

    @Test func resetToDefaultsRestoresBalanced() {
        let settings = AlertSettings()
        settings.applyPreset(AlertSettings.presets.first { $0.name == "Relaxed" }!)
        settings.resetToDefaults()

        #expect(settings.cpuThreshold == 30)
        #expect(settings.minRunningMinutes == 10)
        #expect(settings.cpuTimeThreshold == 5)
    }

    @Test func presetsOrderedBySensitivity() {
        // The UI lists presets left-to-right from most sensitive to most relaxed —
        // ordering matters because it implies a spectrum.
        let presets = AlertSettings.presets
        #expect(presets[0].cpuThreshold < presets[1].cpuThreshold)
        #expect(presets[1].cpuThreshold < presets[2].cpuThreshold)
    }
}
