import Foundation
import Darwin

/// Analyzes processes to find suspicious ones (like Logitech running for 10 months!)
class ProcessAnalyzer {
    private let cpuMonitor = CPUMonitor()
    private let settings = AlertSettings.shared

    // System processes to ignore
    private let systemProcesses: Set<String> = [
        "kernel_task", "launchd", "UserEventAgent", "distnoted",
        "cfprefsd", "trustd", "secd", "securityd", "syspolicyd",
        "coreauthd", "coreservicesd", "WindowServer", "loginwindow",
        "Finder", "Dock", "SystemUIServer", "AirPlayUIAgent",
        "ControlCenter", "NotificationCenter", "Spotlight",
        "mds", "mds_stores", "mdworker", "mdworker_shared",
        "softwareupdated", "installd", "xpcproxy", "logd",
        "powerd", "bluetoothd", "apsd", "cloudd", "bird"
    ]

    // Thresholds for anomaly detection (now configurable via AlertSettings)
    private var cpuThresholdPercent: Double { settings.cpuThreshold }
    private var minRunningMinutes: Double { settings.minRunningMinutes }
    private var cpuTimeThresholdMinutes: Double { settings.cpuTimeThreshold }

    /// Find processes consuming resources abnormally.
    /// Thin wrapper around the pure static so the kernel-IO side-effect
    /// (`getProcessList()`) is the only thing in the instance method.
    func findSuspiciousProcesses() -> [ProcessInfo] {
        Self.findSuspiciousProcesses(
            in: cpuMonitor.getProcessList(),
            cpuThresholdPercent: cpuThresholdPercent,
            minRunningMinutes: minRunningMinutes,
            cpuTimeThresholdMinutes: cpuTimeThresholdMinutes,
            now: Date(),
            skipping: systemProcesses
        )
    }

    /// Pure variant of `findSuspiciousProcesses()`. Testable without
    /// `proc_listallpids`. The detection rule mirrors the original —
    /// long-running process with high *average* CPU since start, above
    /// the configured CPU-time floor.
    static func findSuspiciousProcesses(
        in processes: [ProcessBasicInfo],
        cpuThresholdPercent: Double,
        minRunningMinutes: Double,
        cpuTimeThresholdMinutes: Double,
        now: Date,
        skipping systemProcesses: Set<String>
    ) -> [ProcessInfo] {
        var suspicious: [ProcessInfo] = []

        for proc in processes {
            if systemProcesses.contains(proc.name) { continue }

            let runningMinutes = now.timeIntervalSince(proc.startTime) / 60
            if runningMinutes < minRunningMinutes { continue }

            let cpuTimeMinutes = proc.cpuTimeSeconds / 60
            let cpuPercent = (cpuTimeMinutes / runningMinutes) * 100

            // Suspicious = consumed a lot of CPU time over its lifetime
            // AND that averages out to a high CPU%. The runaway-Logitech
            // case is the canonical example.
            guard cpuTimeMinutes > cpuTimeThresholdMinutes,
                  cpuPercent > cpuThresholdPercent else { continue }

            suspicious.append(ProcessInfo(
                id: proc.pid,
                name: proc.name,
                cpuPercent: cpuPercent,
                memoryBytes: proc.memoryBytes,
                startTime: proc.startTime,
                cpuTimeMinutes: cpuTimeMinutes
            ))
        }

        return suspicious.sorted { $0.cpuPercent > $1.cpuPercent }
    }

    /// Find processes known as bloatware. Thin wrapper around the pure
    /// static — `getProcessList()` is the only side effect.
    func findKnownBloatware() -> [BloatwareMatch] {
        Self.findKnownBloatware(
            in: cpuMonitor.getProcessList(),
            knownBloatware: loadKnownBloatware()
        )
    }

    /// Pure variant of `findKnownBloatware()`. Aggregates **per bloatware
    /// entry**, not per pattern — the previous implementation produced
    /// one `BloatwareMatch` per matching pattern, so an entry like Adobe
    /// Creative Cloud (5 process patterns) appeared up to 5 times in the
    /// Alerts tab, each card containing only the process matched by that
    /// one pattern. Now every entry collapses into a single match whose
    /// `runningProcesses` is the union and `totalMemoryBytes` is the
    /// sum, deduplicated by PID so a process matched by two patterns
    /// isn't counted twice.
    ///
    /// All matching is case-insensitive substring (`processName.contains
    /// (pattern)`), preserved from the previous behaviour. Lower-cased
    /// process names are computed once instead of per pattern.
    static func findKnownBloatware(
        in processes: [ProcessBasicInfo],
        knownBloatware: [KnownBloatware]
    ) -> [BloatwareMatch] {
        let loweredProcesses: [(name: String, lowered: String, pid: Int32, memory: UInt64)] =
            processes.map { ($0.name, $0.name.lowercased(), $0.pid, $0.memoryBytes) }

        var matches: [BloatwareMatch] = []

        for bloatware in knownBloatware {
            let loweredPatterns = bloatware.processes.map { $0.lowercased() }
            var matchedPIDs = Set<Int32>()
            var names: [String] = []
            var totalMemory: UInt64 = 0

            for proc in loweredProcesses {
                guard loweredPatterns.contains(where: { proc.lowered.contains($0) }) else { continue }
                if matchedPIDs.insert(proc.pid).inserted {
                    names.append(proc.name)
                    totalMemory += proc.memory
                }
            }

            if !matchedPIDs.isEmpty {
                matches.append(BloatwareMatch(
                    bloatware: bloatware,
                    runningProcesses: names,
                    totalMemoryBytes: totalMemory
                ))
            }
        }

        return matches
    }

    /// Load bloatware database from JSON
    private func loadKnownBloatware() -> [KnownBloatware] {
        guard let url = Bundle.main.url(forResource: "KnownBloatware", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let container = try? JSONDecoder().decode(BloatwareContainer.self, from: data) else {
            // Fallback: return default hardcoded list
            return getDefaultBloatwareList()
        }
        return container.knownBloatware
    }

    /// Default bloatware list (fallback)
    private func getDefaultBloatwareList() -> [KnownBloatware] {
        return [
            KnownBloatware(
                name: "CleanMyMac",
                processes: ["CleanMyMac", "moonlock", "HealthMonitor"],
                reason: "Unnecessary antivirus on Mac, wastes RAM and CPU",
                removalSafe: true
            ),
            KnownBloatware(
                name: "Logitech Options+",
                processes: ["logioptionsplus", "LogiMgr"],
                reason: "Updater often gets stuck in CPU loop (known bug)",
                removalSafe: true
            ),
            KnownBloatware(
                name: "Adobe Creative Cloud",
                processes: ["AdobeIPCBroker", "CCLibrary", "CCXProcess", "Adobe Desktop Service", "AdobeUpdateManager"],
                reason: "Many background processes even without Adobe apps open",
                removalSafe: false
            ),
            KnownBloatware(
                name: "Boom Audio",
                processes: ["Boom", "BoomAudio"],
                reason: "Can cause audio issues and high CPU usage",
                removalSafe: true
            ),
            KnownBloatware(
                name: "McAfee",
                processes: ["McAfee", "MFEFirewall", "Mfecds"],
                reason: "Unnecessary antivirus on Mac, slows down the system",
                removalSafe: true
            ),
            KnownBloatware(
                name: "Norton",
                processes: ["Norton", "NortonSecurity", "SymDaemon"],
                reason: "Unnecessary antivirus on Mac, slows down the system",
                removalSafe: true
            ),
            KnownBloatware(
                name: "Dropbox",
                processes: ["Dropbox"],
                reason: "Can use high CPU during sync (not always problematic)",
                removalSafe: true
            )
        ]
    }

    /// Get top processes by CPU usage
    func getTopProcessesByCPU(limit: Int = 10) -> [ProcessInfo] {
        let processes = cpuMonitor.getProcessList()
        let now = Date()

        let processInfos = processes.compactMap { proc -> ProcessInfo? in
            let runningMinutes = max(1, now.timeIntervalSince(proc.startTime) / 60)
            let cpuTimeMinutes = proc.cpuTimeSeconds / 60
            let cpuPercent = (cpuTimeMinutes / runningMinutes) * 100

            return ProcessInfo(
                id: proc.pid,
                name: proc.name,
                cpuPercent: cpuPercent,
                memoryBytes: proc.memoryBytes,
                startTime: proc.startTime,
                cpuTimeMinutes: cpuTimeMinutes
            )
        }

        return Array(processInfos.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(limit))
    }
}

// MARK: - Models

/// Known bloatware
struct KnownBloatware: Codable {
    let name: String
    let processes: [String]
    let reason: String
    let removalSafe: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case processes
        case reason
        case removalSafe = "removal_safe"
    }
}

/// Container for JSON
struct BloatwareContainer: Codable {
    let knownBloatware: [KnownBloatware]

    enum CodingKeys: String, CodingKey {
        case knownBloatware = "known_bloatware"
    }
}

/// Match between process and bloatware
struct BloatwareMatch {
    let bloatware: KnownBloatware
    let runningProcesses: [String]
    let totalMemoryBytes: UInt64

    var memoryFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalMemoryBytes), countStyle: .memory)
    }
}
