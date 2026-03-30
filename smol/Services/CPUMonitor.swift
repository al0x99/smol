import Foundation
import Darwin

/// Monitora l'utilizzo CPU usando libproc
class CPUMonitor {
    private var previousIdleTime: UInt64 = 0
    private var previousTotalTime: UInt64 = 0

    /// Restituisce la percentuale di CPU idle (0-100)
    func getIdlePercent() -> Double {
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        var numCPUs: natural_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUs,
            &cpuInfo,
            &numCpuInfo
        )

        guard result == KERN_SUCCESS, let cpuInfo = cpuInfo else {
            return 100 // Default a idle se errore
        }

        var totalUser: UInt64 = 0
        var totalSystem: UInt64 = 0
        var totalIdle: UInt64 = 0
        var totalNice: UInt64 = 0

        for i in 0..<Int(numCPUs) {
            let offset = Int(CPU_STATE_MAX) * i
            totalUser += UInt64(cpuInfo[offset + Int(CPU_STATE_USER)])
            totalSystem += UInt64(cpuInfo[offset + Int(CPU_STATE_SYSTEM)])
            totalIdle += UInt64(cpuInfo[offset + Int(CPU_STATE_IDLE)])
            totalNice += UInt64(cpuInfo[offset + Int(CPU_STATE_NICE)])
        }

        let totalTime = totalUser + totalSystem + totalIdle + totalNice

        // Calcola delta dal campione precedente
        let idleDelta = totalIdle - previousIdleTime
        let totalDelta = totalTime - previousTotalTime

        previousIdleTime = totalIdle
        previousTotalTime = totalTime

        // Prima lettura: restituisce stima basata su valori assoluti
        if totalDelta == 0 {
            return Double(totalIdle) / Double(totalTime) * 100
        }

        // Deallocazione memoria
        let size = vm_size_t(numCpuInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), size)

        return Double(idleDelta) / Double(totalDelta) * 100
    }

    /// Restituisce lista di processi con info CPU
    func getProcessList() -> [ProcessBasicInfo] {
        var processes: [ProcessBasicInfo] = []

        // Ottieni numero di processi
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size: Int = 0

        // Prima chiamata per ottenere size
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else {
            return []
        }

        // Alloca buffer
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)

        // Seconda chiamata per ottenere dati
        guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else {
            return []
        }

        let actualCount = size / MemoryLayout<kinfo_proc>.stride

        for i in 0..<actualCount {
            let proc = procs[i]
            let pid = proc.kp_proc.p_pid

            // Salta processi di sistema con PID <= 0
            guard pid > 0 else { continue }

            // Ottieni nome processo
            var name = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            proc_name(pid, &name, UInt32(MAXPATHLEN))
            let processName = String(cString: name)

            // Salta processi senza nome
            guard !processName.isEmpty else { continue }

            // Ottieni CPU time
            var taskInfo = proc_taskinfo()
            let taskInfoSize = Int32(MemoryLayout<proc_taskinfo>.size)
            let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, taskInfoSize)

            guard result == taskInfoSize else { continue }

            // Converti CPU time in secondi
            let userTime = Double(taskInfo.pti_total_user) / 1_000_000_000
            let systemTime = Double(taskInfo.pti_total_system) / 1_000_000_000
            let totalCpuTime = userTime + systemTime

            // Ottieni start time
            let startTimeSec = Double(proc.kp_proc.p_starttime.tv_sec)
            let startDate = Date(timeIntervalSince1970: startTimeSec)

            let info = ProcessBasicInfo(
                pid: pid,
                name: processName,
                cpuTimeSeconds: totalCpuTime,
                memoryBytes: UInt64(taskInfo.pti_resident_size),
                startTime: startDate
            )

            processes.append(info)
        }

        return processes
    }
}

/// Info base su un processo (usato internamente)
struct ProcessBasicInfo {
    let pid: Int32
    let name: String
    let cpuTimeSeconds: Double
    let memoryBytes: UInt64
    let startTime: Date
}
