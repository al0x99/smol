import Foundation
import IOKit

/// Traccia l'utilizzo risorse durante operazioni AI
/// Fornisce trasparenza all'utente sul costo computazionale
class ResourceTracker {
    static let shared = ResourceTracker()

    // MARK: - Types

    struct ResourceSnapshot {
        let timestamp: Date
        let cpuUsage: Double          // Percentuale 0-100
        let memoryUsed: UInt64        // Bytes
        let memoryPressure: Double    // Percentuale 0-100
        let energyImpact: Double      // Stima 0-100
    }

    struct ResourceCost: CustomStringConvertible {
        let duration: TimeInterval
        let avgCPU: Double
        let peakCPU: Double
        let memoryDelta: Int64        // Bytes (può essere negativo)
        let peakMemory: UInt64
        let estimatedEnergy: Double   // mWh stimati
        let tokenCount: Int?          // Per LLM

        var description: String {
            var parts: [String] = []
            parts.append(String(format: "⏱ %.1fs", duration))
            parts.append(String(format: "CPU: avg %.0f%% peak %.0f%%", avgCPU, peakCPU))

            let memMB = Double(abs(memoryDelta)) / 1_048_576
            let memSign = memoryDelta >= 0 ? "+" : "-"
            parts.append(String(format: "RAM: %@%.1f MB", memSign, memMB))

            parts.append(String(format: "⚡ ~%.2f mWh", estimatedEnergy))

            if let tokens = tokenCount {
                let tokensPerSec = duration > 0 ? Double(tokens) / duration : 0
                parts.append(String(format: "🔤 %d tokens (%.1f/s)", tokens, tokensPerSec))
            }

            return parts.joined(separator: " | ")
        }

        /// Descrizione user-friendly per UI
        var userFriendlyDescription: String {
            let impact = impactLevel
            let emoji = impact == .low ? "🟢" : (impact == .medium ? "🟡" : "🔴")

            var desc = "\(emoji) "

            switch impact {
            case .low:
                desc += "Impatto leggero"
            case .medium:
                desc += "Impatto moderato"
            case .high:
                desc += "Impatto elevato"
            }

            desc += String(format: " (%.1fs, ~%.2f mWh)", duration, estimatedEnergy)
            return desc
        }

        var impactLevel: ImpactLevel {
            if avgCPU < 30 && estimatedEnergy < 0.5 {
                return .low
            } else if avgCPU < 70 && estimatedEnergy < 2.0 {
                return .medium
            } else {
                return .high
            }
        }

        enum ImpactLevel: String {
            case low = "Basso"
            case medium = "Medio"
            case high = "Alto"
        }
    }

    // MARK: - Private State

    private var startSnapshot: ResourceSnapshot?
    private var samples: [ResourceSnapshot] = []
    private var samplingTimer: Timer?
    private var tokenCounter: Int = 0

    // MARK: - Tracking API

    /// Inizia a tracciare le risorse
    func startTracking() {
        samples = []
        tokenCounter = 0
        startSnapshot = takeSnapshot()

        // Campiona ogni 100ms
        samplingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.samples.append(self?.takeSnapshot() ?? ResourceSnapshot(
                timestamp: Date(),
                cpuUsage: 0,
                memoryUsed: 0,
                memoryPressure: 0,
                energyImpact: 0
            ))
        }
    }

    /// Incrementa contatore token (per LLM)
    func addTokens(_ count: Int) {
        tokenCounter += count
    }

    /// Ferma il tracking e restituisce il costo
    func stopTracking() -> ResourceCost {
        samplingTimer?.invalidate()
        samplingTimer = nil

        let endSnapshot = takeSnapshot()

        guard let start = startSnapshot else {
            return ResourceCost(
                duration: 0,
                avgCPU: 0,
                peakCPU: 0,
                memoryDelta: 0,
                peakMemory: 0,
                estimatedEnergy: 0,
                tokenCount: nil
            )
        }

        let duration = endSnapshot.timestamp.timeIntervalSince(start.timestamp)

        // Calcola statistiche CPU
        let cpuValues = samples.map { $0.cpuUsage }
        let avgCPU = cpuValues.isEmpty ? 0 : cpuValues.reduce(0, +) / Double(cpuValues.count)
        let peakCPU = cpuValues.max() ?? 0

        // Calcola delta memoria
        let memoryDelta = Int64(endSnapshot.memoryUsed) - Int64(start.memoryUsed)
        let peakMemory = samples.map { $0.memoryUsed }.max() ?? endSnapshot.memoryUsed

        // Stima energia (approssimativa)
        // Apple Silicon: ~15W TDP, assumiamo proporzionale a CPU%
        let avgPowerWatts = (avgCPU / 100.0) * 15.0
        let energyWh = (avgPowerWatts * duration) / 3600.0
        let energyMWh = energyWh * 1000.0

        startSnapshot = nil

        return ResourceCost(
            duration: duration,
            avgCPU: avgCPU,
            peakCPU: peakCPU,
            memoryDelta: memoryDelta,
            peakMemory: peakMemory,
            estimatedEnergy: energyMWh,
            tokenCount: tokenCounter > 0 ? tokenCounter : nil
        )
    }

    /// Esegue un'operazione tracciando le risorse
    func track<T>(operation: () async throws -> T) async throws -> (result: T, cost: ResourceCost) {
        startTracking()
        do {
            let result = try await operation()
            let cost = stopTracking()
            return (result, cost)
        } catch {
            _ = stopTracking()
            throw error
        }
    }

    /// Versione sincrona
    func trackSync<T>(operation: () throws -> T) throws -> (result: T, cost: ResourceCost) {
        startTracking()
        do {
            let result = try operation()
            let cost = stopTracking()
            return (result, cost)
        } catch {
            _ = stopTracking()
            throw error
        }
    }

    // MARK: - Snapshot

    private func takeSnapshot() -> ResourceSnapshot {
        return ResourceSnapshot(
            timestamp: Date(),
            cpuUsage: getCurrentCPUUsage(),
            memoryUsed: getCurrentMemoryUsage(),
            memoryPressure: getCurrentMemoryPressure(),
            energyImpact: estimateEnergyImpact()
        )
    }

    // MARK: - System Metrics

    private func getCurrentCPUUsage() -> Double {
        var totalUsage: Double = 0
        var threadsList: thread_act_array_t?
        var threadsCount = mach_msg_type_number_t(0)

        let task = mach_task_self_

        guard task_threads(task, &threadsList, &threadsCount) == KERN_SUCCESS,
              let threads = threadsList else {
            return 0
        }

        for i in 0..<Int(threadsCount) {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(THREAD_INFO_MAX)

            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }

            if result == KERN_SUCCESS && info.flags & TH_FLAGS_IDLE == 0 {
                totalUsage += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
            }
        }

        vm_deallocate(task, vm_address_t(bitPattern: threads), vm_size_t(Int(threadsCount) * MemoryLayout<thread_t>.stride))

        return min(totalUsage, 100.0)
    }

    private func getCurrentMemoryUsage() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

        if result == KERN_SUCCESS {
            return info.resident_size
        }
        return 0
    }

    private func getCurrentMemoryPressure() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0 }

        let pageSize = UInt64(vm_kernel_page_size)
        let active = UInt64(stats.active_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize

        let totalPhysical = Foundation.ProcessInfo.processInfo.physicalMemory
        let pressureUsed = active + wired + compressed

        return Double(pressureUsed) / Double(totalPhysical) * 100.0
    }

    private func estimateEnergyImpact() -> Double {
        // Stima basata su CPU e memoria
        let cpu = getCurrentCPUUsage()
        let memPressure = getCurrentMemoryPressure()

        return (cpu * 0.7 + memPressure * 0.3)
    }
}

// MARK: - Cost Estimation Helpers

extension ResourceTracker {
    /// Stima il costo prima di eseguire (per avvisare l'utente)
    struct CostEstimate {
        let estimatedDuration: TimeInterval
        let estimatedCPU: Double
        let estimatedMemoryMB: Double
        let estimatedEnergyMWh: Double
        let warning: String?

        var displayText: String {
            var text = String(format: "~%.0fs, ~%.0f%% CPU, ~%.0f MB RAM",
                              estimatedDuration, estimatedCPU, estimatedMemoryMB)
            if let warning = warning {
                text += "\n⚠️ \(warning)"
            }
            return text
        }
    }

    /// Stima costo per LLM inference
    static func estimateLLMCost(inputTokens: Int, modelSize: ModelSize) -> CostEstimate {
        let tokensPerSecond: Double
        let cpuUsage: Double
        let memoryMB: Double

        switch modelSize {
        case .tiny:    // ~1B params
            tokensPerSecond = 30
            cpuUsage = 40
            memoryMB = 800
        case .small:   // ~3B params
            tokensPerSecond = 15
            cpuUsage = 60
            memoryMB = 2000
        case .medium:  // ~7B params
            tokensPerSecond = 8
            cpuUsage = 80
            memoryMB = 4500
        case .large:   // ~13B+ params
            tokensPerSecond = 4
            cpuUsage = 95
            memoryMB = 9000
        }

        // Stima output tokens (circa 2x input per risposte)
        let estimatedOutputTokens = inputTokens * 2
        let totalTokens = inputTokens + estimatedOutputTokens
        let duration = Double(totalTokens) / tokensPerSecond

        let powerWatts = (cpuUsage / 100.0) * 15.0
        let energyMWh = (powerWatts * duration / 3600.0) * 1000.0

        var warning: String? = nil
        if modelSize == .large {
            warning = "Modello grande: impatto significativo su batteria e performance"
        } else if modelSize == .medium {
            warning = "Potrebbe rallentare altre app durante l'esecuzione"
        }

        return CostEstimate(
            estimatedDuration: duration,
            estimatedCPU: cpuUsage,
            estimatedMemoryMB: memoryMB,
            estimatedEnergyMWh: energyMWh,
            warning: warning
        )
    }

    enum ModelSize: String, CaseIterable {
        case tiny = "Tiny (~1B)"
        case small = "Small (~3B)"
        case medium = "Medium (~7B)"
        case large = "Large (~13B+)"
    }
}
