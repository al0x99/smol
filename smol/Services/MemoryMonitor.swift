import Foundation
import Darwin

/// Monitors memory using memory_pressure and VM statistics
class MemoryMonitor {

    /// Gets complete memory information
    func getMemoryInfo() -> MemoryInfo {
        let pressure = getMemoryPressurePercent()
        let (used, total) = getMemoryUsage()
        let swap = getSwapUsage()

        return MemoryInfo(
            used: used,
            total: total,
            pressure: pressure,
            swapUsed: swap
        )
    }

    /// Gets the memory pressure percentage (0-100)
    /// This is the TRUE value that matters, not the GB used
    private func getMemoryPressurePercent() -> Double {
        // Use vm_statistics64 to calculate pressure
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) { statsPtr in
            statsPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ptr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, ptr, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return 0
        }

        // Calculate pressure based on compressed pages and swap
        let compressedPages = UInt64(stats.compressor_page_count)
        let totalPages = UInt64(stats.free_count + stats.active_count + stats.inactive_count + stats.wire_count + stats.compressor_page_count)

        // Pressure is high when there are many compressed pages relative to total
        // and when the system is actively paging
        let compressionRatio = Double(compressedPages) / Double(max(totalPages, 1))
        let pagingActivity = Double(stats.pageouts) / 1000.0 // Normalizza

        // Simplified formula for pressure
        let pressure = min(100, (compressionRatio * 100) + min(50, pagingActivity))

        return pressure
    }

    /// Gets used and total memory in bytes
    private func getMemoryUsage() -> (used: UInt64, total: UInt64) {
        // Total physical memory
        var memSize: UInt64 = 0
        var sizeOfMemSize = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memSize, &sizeOfMemSize, nil, 0)

        // VM statistics
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) { statsPtr in
            statsPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ptr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, ptr, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return (0, memSize)
        }

        let pageSize = UInt64(vm_kernel_page_size)

        // Memory "used" = wired + active (does not include inactive/cache/free)
        // inactive is memory that can be freed immediately
        let wired = UInt64(stats.wire_count) * pageSize
        let active = UInt64(stats.active_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize

        let used = wired + active + compressed

        return (used, memSize)
    }

    /// Gets swap used in bytes
    private func getSwapUsage() -> UInt64 {
        var swapUsage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size

        let result = sysctlbyname("vm.swapusage", &swapUsage, &size, nil, 0)

        guard result == 0 else {
            return 0
        }

        return swapUsage.xsu_used
    }

    /// Alternative method: runs the memory_pressure command
    /// More accurate but slower
    func getMemoryPressureFromCommand() -> (level: String, percent: Double) {
        let task = Process()
        let pipe = Pipe()

        task.standardOutput = pipe
        task.standardError = pipe
        task.executableURL = URL(fileURLWithPath: "/usr/bin/memory_pressure")

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            // Parse output: "System-wide memory free percentage: 97%"
            if let range = output.range(of: "free percentage: ") {
                let percentStr = output[range.upperBound...]
                    .prefix(while: { $0.isNumber })
                if let freePercent = Double(percentStr) {
                    let usedPercent = 100 - freePercent
                    let level = usedPercent < 50 ? "LOW" : (usedPercent < 80 ? "MEDIUM" : "HIGH")
                    return (level, usedPercent)
                }
            }
        } catch {
            // Silent fallback
        }

        return ("UNKNOWN", 0)
    }
}
