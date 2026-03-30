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

    /// Find processes consuming resources abnormally
    func findSuspiciousProcesses() -> [ProcessInfo] {
        var suspicious: [ProcessInfo] = []
        let processes = cpuMonitor.getProcessList()
        let now = Date()

        for proc in processes {
            // Skip system processes
            if systemProcesses.contains(proc.name) {
                continue
            }

            // Skip processes that started too recently
            let runningMinutes = now.timeIntervalSince(proc.startTime) / 60
            if runningMinutes < minRunningMinutes {
                continue
            }

            // Calculate average CPU % based on CPU time and running time
            let cpuTimeMinutes = proc.cpuTimeSeconds / 60
            let cpuPercent = (cpuTimeMinutes / runningMinutes) * 100

            // Process is suspicious if:
            // 1. Has consumed a lot of CPU time (like Logitech running for 10 months)
            // 2. High average CPU % for a long-running process
            let isSuspicious = cpuTimeMinutes > cpuTimeThresholdMinutes &&
                               cpuPercent > cpuThresholdPercent

            if isSuspicious {
                let processInfo = ProcessInfo(
                    id: proc.pid,
                    name: proc.name,
                    cpuPercent: cpuPercent,
                    memoryBytes: proc.memoryBytes,
                    startTime: proc.startTime,
                    cpuTimeMinutes: cpuTimeMinutes
                )
                suspicious.append(processInfo)
            }
        }

        // Sort by CPU % descending
        return suspicious.sorted { $0.cpuPercent > $1.cpuPercent }
    }

    /// Find processes known as bloatware
    func findKnownBloatware() -> [BloatwareMatch] {
        var matches: [BloatwareMatch] = []
        let processes = cpuMonitor.getProcessList()
        let knownBloatware = loadKnownBloatware()

        for bloatware in knownBloatware {
            for pattern in bloatware.processes {
                let matchingProcs = processes.filter {
                    $0.name.lowercased().contains(pattern.lowercased())
                }

                if !matchingProcs.isEmpty {
                    let match = BloatwareMatch(
                        bloatware: bloatware,
                        runningProcesses: matchingProcs.map { $0.name },
                        totalMemoryBytes: matchingProcs.reduce(0) { $0 + $1.memoryBytes }
                    )
                    matches.append(match)
                }
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
