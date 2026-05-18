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

        // `host_processor_info` allocates the cpuInfo buffer on our
        // behalf. The previous code freed it inline between two return
        // paths, which leaked the buffer on the first-reading early
        // return — and that path runs on every fresh launch. A `defer`
        // guarantees the deallocation regardless of which return path
        // we take.
        defer {
            let size = vm_size_t(numCpuInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), size)
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
        let percent = Self.idlePercent(
            currentIdle: totalIdle,
            currentTotal: totalTime,
            previousIdle: previousIdleTime,
            previousTotal: previousTotalTime
        )

        previousIdleTime = totalIdle
        previousTotalTime = totalTime
        return percent
    }

    /// Pure mapping from cumulative-tick counters to the instantaneous
    /// idle percentage. On the first call the deltas are zero and the
    /// snapshot is meaningless, so we fall back to the lifetime
    /// average — one tick of "off" reading before the delta-based
    /// values stabilise, which is fine for a 2 s polling widget.
    static func idlePercent(
        currentIdle: UInt64,
        currentTotal: UInt64,
        previousIdle: UInt64,
        previousTotal: UInt64
    ) -> Double {
        let totalDelta = currentTotal &- previousTotal
        let idleDelta = currentIdle &- previousIdle

        guard totalDelta > 0 else {
            // First reading after launch (or counter wrap, which on
            // 64-bit Mach tick counters won't realistically happen).
            // Use the lifetime average as a best-effort seed.
            return currentTotal > 0
                ? Double(currentIdle) / Double(currentTotal) * 100
                : 100
        }

        // idleDelta can briefly exceed totalDelta on aggressive
        // power-state transitions; clamp so the UI never shows >100%.
        let raw = Double(idleDelta) / Double(totalDelta) * 100
        return min(100, max(0, raw))
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

        // Bound by the allocated buffer size. `sysctl` updates `size`
        // to the bytes it actually wrote, but on Darwin if the process
        // table grew between the two sysctl calls it can in theory
        // report more bytes than the buffer holds. Clamping prevents an
        // out-of-bounds read in that race.
        let actualCount = min(size / MemoryLayout<kinfo_proc>.stride, count)

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
