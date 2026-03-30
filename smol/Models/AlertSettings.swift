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
    Quanto CPU deve usare un processo per essere considerato "alto".

    • 20-30%: Sensibile - rileva più processi
    • 30-50%: Bilanciato (consigliato)
    • 50%+: Solo processi molto intensivi

    Processi come browser o IDE possono usare 20-40% normalmente.
    """

    /// Tip for minimum running time
    static let minRunningTip = """
    Quanto tempo deve girare un processo prima di analizzarlo.

    • 5 min: Rileva problemi rapidamente
    • 10 min: Bilanciato (consigliato)
    • 30+ min: Solo processi che girano da molto

    Valori bassi possono generare falsi positivi per processi temporanei.
    """

    /// Tip for CPU threshold time
    static let cpuTimeTip = """
    Quanti minuti di lavoro CPU effettivo deve accumulare un processo.

    • 2-5 min: Sensibile
    • 5-10 min: Bilanciato (consigliato)
    • 15+ min: Solo processi che lavorano molto

    Un processo in background che usa 50% CPU per 20 minuti
    accumula 10 minuti di CPU time.
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
            name: "Sensibile",
            description: "Rileva più anomalie",
            cpuThreshold: 20,
            minRunningMinutes: 5,
            cpuTimeThreshold: 3,
            icon: "eye.fill"
        ),
        Preset(
            name: "Bilanciato",
            description: "Consigliato",
            cpuThreshold: 30,
            minRunningMinutes: 10,
            cpuTimeThreshold: 5,
            icon: "scale.3d"
        ),
        Preset(
            name: "Rilassato",
            description: "Solo problemi seri",
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
