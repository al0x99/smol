import Foundation
import Darwin

/// Monitora la memoria usando memory_pressure e statistiche VM
class MemoryMonitor {

    /// Ottiene informazioni complete sulla memoria
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

    /// Ottiene la percentuale di memory pressure (0-100)
    /// Questo è il valore VERO che conta, non i GB usati
    private func getMemoryPressurePercent() -> Double {
        // Usa vm_statistics64 per calcolare la pressione
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

        // Calcola pressione basata su pagine compresse e swap
        let compressedPages = UInt64(stats.compressor_page_count)
        let totalPages = UInt64(stats.free_count + stats.active_count + stats.inactive_count + stats.wire_count + stats.compressor_page_count)

        // La pressione è alta quando ci sono molte pagine compresse rispetto al totale
        // e quando il sistema sta facendo paging attivo
        let compressionRatio = Double(compressedPages) / Double(max(totalPages, 1))
        let pagingActivity = Double(stats.pageouts) / 1000.0 // Normalizza

        // Formula semplificata per pressure
        let pressure = min(100, (compressionRatio * 100) + min(50, pagingActivity))

        return pressure
    }

    /// Ottiene memoria usata e totale in bytes
    private func getMemoryUsage() -> (used: UInt64, total: UInt64) {
        // Memoria fisica totale
        var memSize: UInt64 = 0
        var sizeOfMemSize = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memSize, &sizeOfMemSize, nil, 0)

        // Statistiche VM
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

        // Memoria "usata" = wired + active (non include inactive/cache/free)
        // inactive è memoria che può essere liberata immediatamente
        let wired = UInt64(stats.wire_count) * pageSize
        let active = UInt64(stats.active_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize

        let used = wired + active + compressed

        return (used, memSize)
    }

    /// Ottiene swap usato in bytes
    private func getSwapUsage() -> UInt64 {
        var swapUsage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size

        let result = sysctlbyname("vm.swapusage", &swapUsage, &size, nil, 0)

        guard result == 0 else {
            return 0
        }

        return swapUsage.xsu_used
    }

    /// Metodo alternativo: esegue il comando memory_pressure
    /// Più accurato ma più lento
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
            // Fallback silenzioso
        }

        return ("UNKNOWN", 0)
    }
}
