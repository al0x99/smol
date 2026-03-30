import Foundation
import Darwin

/// Analizza i processi per trovare quelli sospetti (come Logitech che gira per 10 mesi!)
class ProcessAnalyzer {
    private let cpuMonitor = CPUMonitor()

    // Processi di sistema da ignorare
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

    // Soglie per rilevamento anomalie
    private let cpuThresholdPercent: Double = 30      // CPU > 30% considerata alta
    private let minRunningMinutes: Double = 10        // Deve girare da almeno 10 min
    private let cpuTimeThresholdMinutes: Double = 5   // CPU time accumulato > 5 min

    /// Trova processi che consumano risorse in modo anomalo
    func findSuspiciousProcesses() -> [ProcessInfo] {
        var suspicious: [ProcessInfo] = []
        let processes = cpuMonitor.getProcessList()
        let now = Date()

        for proc in processes {
            // Salta processi di sistema
            if systemProcesses.contains(proc.name) {
                continue
            }

            // Salta processi troppo recenti
            let runningMinutes = now.timeIntervalSince(proc.startTime) / 60
            if runningMinutes < minRunningMinutes {
                continue
            }

            // Calcola CPU % media basata su CPU time e tempo di esecuzione
            let cpuTimeMinutes = proc.cpuTimeSeconds / 60
            let cpuPercent = (cpuTimeMinutes / runningMinutes) * 100

            // Processo sospetto se:
            // 1. Ha consumato molto CPU time (tipo Logitech che girava da 10 mesi)
            // 2. CPU % media alta per processo che gira da molto
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

        // Ordina per CPU % decrescente
        return suspicious.sorted { $0.cpuPercent > $1.cpuPercent }
    }

    /// Trova processi noti come bloatware
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

    /// Carica database bloatware da JSON
    private func loadKnownBloatware() -> [KnownBloatware] {
        guard let url = Bundle.main.url(forResource: "KnownBloatware", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let container = try? JSONDecoder().decode(BloatwareContainer.self, from: data) else {
            // Fallback: ritorna lista hardcoded
            return getDefaultBloatwareList()
        }
        return container.knownBloatware
    }

    /// Lista bloatware di default (fallback)
    private func getDefaultBloatwareList() -> [KnownBloatware] {
        return [
            KnownBloatware(
                name: "CleanMyMac",
                processes: ["CleanMyMac", "moonlock", "HealthMonitor"],
                reason: "Antivirus inutile su Mac, consuma RAM e CPU",
                removalSafe: true
            ),
            KnownBloatware(
                name: "Logitech Options+",
                processes: ["logioptionsplus", "LogiMgr"],
                reason: "L'updater spesso si blocca in loop CPU (bug noto)",
                removalSafe: true
            ),
            KnownBloatware(
                name: "Adobe Creative Cloud",
                processes: ["AdobeIPCBroker", "CCLibrary", "CCXProcess", "Adobe Desktop Service", "AdobeUpdateManager"],
                reason: "Molti processi background anche senza app Adobe aperte",
                removalSafe: false
            ),
            KnownBloatware(
                name: "Boom Audio",
                processes: ["Boom", "BoomAudio"],
                reason: "Può causare problemi audio e CPU alta",
                removalSafe: true
            ),
            KnownBloatware(
                name: "McAfee",
                processes: ["McAfee", "MFEFirewall", "Mfecds"],
                reason: "Antivirus non necessario su Mac, rallenta il sistema",
                removalSafe: true
            ),
            KnownBloatware(
                name: "Norton",
                processes: ["Norton", "NortonSecurity", "SymDaemon"],
                reason: "Antivirus non necessario su Mac, rallenta il sistema",
                removalSafe: true
            ),
            KnownBloatware(
                name: "Dropbox",
                processes: ["Dropbox"],
                reason: "Può usare molta CPU durante sync (non sempre problematico)",
                removalSafe: true
            )
        ]
    }

    /// Ottiene lista top processi per CPU
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

/// Bloatware conosciuto
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

/// Container per JSON
struct BloatwareContainer: Codable {
    let knownBloatware: [KnownBloatware]

    enum CodingKeys: String, CodingKey {
        case knownBloatware = "known_bloatware"
    }
}

/// Match tra processo e bloatware
struct BloatwareMatch {
    let bloatware: KnownBloatware
    let runningProcesses: [String]
    let totalMemoryBytes: UInt64

    var memoryFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalMemoryBytes), countStyle: .memory)
    }
}
