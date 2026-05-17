import Foundation
import SwiftUI
import Combine

/// Configurable settings for suspicious process detection
class AlertSettings: ObservableObject {
    /// Singleton for global access
    static let shared = AlertSettings()

    // MARK: - Threshold Settings

    /// CPU % threshold above which a process is considered high consumption
    /// Default: 30%
    @AppStorage("alertCPUThreshold") var cpuThreshold: Double = 30 {
        didSet { objectWillChange.send() }
    }

    /// Minimum running minutes before considering a process
    /// Default: 10 minutes
    @AppStorage("alertMinRunningMinutes") var minRunningMinutes: Double = 10 {
        didSet { objectWillChange.send() }
    }

    /// Accumulated CPU time minutes above which a process is suspicious
    /// Default: 5 minutes
    @AppStorage("alertCPUTimeThreshold") var cpuTimeThreshold: Double = 5 {
        didSet { objectWillChange.send() }
    }

    // MARK: - Tips

    /// Tip for CPU threshold
    static let cpuThresholdTip = """
    How much CPU a process must use to count as "high".

    • 20–30%: Sensitive — flags more processes
    • 30–50%: Balanced (recommended)
    • 50%+: Only very intensive processes

    Browsers and IDEs commonly sit at 20–40% during normal use.
    """

    /// Tip for minimum running time
    static let minRunningTip = """
    How long a process must run before smol analyzes it.

    • 5 min: Catches issues quickly
    • 10 min: Balanced (recommended)
    • 30+ min: Only long-running processes

    Low values can produce false positives for short-lived processes.
    """

    /// Tip for CPU threshold time
    static let cpuTimeTip = """
    How many minutes of accumulated CPU work a process must reach.

    • 2–5 min: Sensitive
    • 5–10 min: Balanced (recommended)
    • 15+ min: Only heavy workers

    A background process at 50% CPU for 20 minutes accumulates 10 minutes
    of CPU time.
    """

    // MARK: - Presets

    struct Preset {
        let name: String
        let description: String
        let cpuThreshold: Double
        let minRunningMinutes: Double
        let cpuTimeThreshold: Double
        let icon: String
    }

    static let presets: [Preset] = [
        Preset(
            name: "Sensitive",
            description: "Catches more anomalies",
            cpuThreshold: 20,
            minRunningMinutes: 5,
            cpuTimeThreshold: 3,
            icon: "eye.fill"
        ),
        Preset(
            name: "Balanced",
            description: "Recommended",
            cpuThreshold: 30,
            minRunningMinutes: 10,
            cpuTimeThreshold: 5,
            icon: "scale.3d"
        ),
        Preset(
            name: "Relaxed",
            description: "Serious issues only",
            cpuThreshold: 50,
            minRunningMinutes: 30,
            cpuTimeThreshold: 15,
            icon: "tortoise.fill"
        )
    ]

    /// Apply a preset
    func applyPreset(_ preset: Preset) {
        cpuThreshold = preset.cpuThreshold
        minRunningMinutes = preset.minRunningMinutes
        cpuTimeThreshold = preset.cpuTimeThreshold
    }

    /// Reset to default values
    func resetToDefaults() {
        cpuThreshold = 30
        minRunningMinutes = 10
        cpuTimeThreshold = 5
    }
}
