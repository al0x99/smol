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

    /// Gets the memory pressure percentage (0-100).
    /// This is the value that maps to the LOW/MEDIUM/HIGH chip in the UI
    /// — far more meaningful than "GB used".
    private func getMemoryPressurePercent() -> Double {
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

        let compressedPages = UInt64(stats.compressor_page_count)
        let totalPages = UInt64(stats.free_count
            + stats.active_count
            + stats.inactive_count
            + stats.wire_count
            + stats.compressor_page_count)

        return Self.pressurePercent(compressedPages: compressedPages, totalPages: totalPages)
    }

    /// Pure mapping from page counts to a 0–100 pressure score, so the
    /// formula can be unit-tested without touching `host_statistics64`.
    ///
    /// The previous implementation added `min(50, stats.pageouts /
    /// 1000)` — but `stats.pageouts` is *cumulative since boot*, so on
    /// any machine with non-trivial uptime that term saturated to 50
    /// and pinned the score at ≥50%, which then tripped
    /// `SystemMonitor.calculateHealth()`'s `> 50` "Memory pressure
    /// medium" warning even on a healthy machine. A correct paging-rate
    /// term would require remembering the previous reading; until we
    /// add that, the score is driven purely by compression ratio (the
    /// metric Apple's own `memory_pressure(1)` tool emphasises).
    static func pressurePercent(compressedPages: UInt64, totalPages: UInt64) -> Double {
        guard totalPages > 0 else { return 0 }
        let ratio = Double(compressedPages) / Double(totalPages)
        return min(100, max(0, ratio * 100))
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
}
