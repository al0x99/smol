import Foundation
import Darwin

/// Monitors CPU usage using libproc
class CPUMonitor {
    private var previousIdleTime: UInt64 = 0
    private var previousTotalTime: UInt64 = 0

    /// Returns the CPU idle percentage (0-100)
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
            return 100 // Default to idle on error
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

        // Calculate delta from previous sample
        let idleDelta = totalIdle - previousIdleTime
        let totalDelta = totalTime - previousTotalTime

        previousIdleTime = totalIdle
        previousTotalTime = totalTime

        // First reading: return estimate based on absolute values
        if totalDelta == 0 {
            return Double(totalIdle) / Double(totalTime) * 100
        }

        // Deallocate memory
        let size = vm_size_t(numCpuInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), size)

        return Double(idleDelta) / Double(totalDelta) * 100
    }

    /// Returns list of processes with CPU info
    func getProcessList() -> [ProcessBasicInfo] {
        var processes: [ProcessBasicInfo] = []

        // Get number of processes
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size: Int = 0

        // First call to get size
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else {
            return []
        }

        // Allocate buffer
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)

        // Second call to get data
        guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else {
            return []
        }

        let actualCount = size / MemoryLayout<kinfo_proc>.stride

        for i in 0..<actualCount {
            let proc = procs[i]
            let pid = proc.kp_proc.p_pid

            // Skip system processes with PID <= 0
            guard pid > 0 else { continue }

            // Get process name
            var name = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            proc_name(pid, &name, UInt32(MAXPATHLEN))
            let processName = String(cString: name)

            // Skip processes without a name
            guard !processName.isEmpty else { continue }

            // Get CPU time
            var taskInfo = proc_taskinfo()
            let taskInfoSize = Int32(MemoryLayout<proc_taskinfo>.size)
            let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, taskInfoSize)

            guard result == taskInfoSize else { continue }

            // Convert CPU time to seconds
            let userTime = Double(taskInfo.pti_total_user) / 1_000_000_000
            let systemTime = Double(taskInfo.pti_total_system) / 1_000_000_000
            let totalCpuTime = userTime + systemTime

            // Get start time
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

/// Basic process info (used internally)
struct ProcessBasicInfo {
    let pid: Int32
    let name: String
    let cpuTimeSeconds: Double
    let memoryBytes: UInt64
    let startTime: Date
}
