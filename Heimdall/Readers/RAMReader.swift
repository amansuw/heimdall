import Foundation

struct RAMReaderResult: Sendable {
    let memory: MemoryBreakdown
}

class RAMReader {
    func read() -> RAMReaderResult {
        var memory = MemoryBreakdown()
        memory.total = ProcessInfo.processInfo.physicalMemory

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return RAMReaderResult(memory: memory)
        }

        let pageSize = UInt64(vm_kernel_page_size)
        let active = UInt64(stats.active_count) * pageSize
        let inactive = UInt64(stats.inactive_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let free = UInt64(stats.free_count) * pageSize
        let speculative = UInt64(stats.speculative_count) * pageSize

        memory.wired = wired
        memory.compressed = compressed
        memory.free = free + speculative + inactive
        memory.app = active
        memory.used = memory.total - memory.free
        memory.pressureLevel = readPressureLevel()

        // Swap
        var swapUsage = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swapUsage, &swapSize, nil, 0) == 0 {
            memory.swap = UInt64(swapUsage.xsu_used)
        }

        return RAMReaderResult(memory: memory)
    }

    private func readPressureLevel() -> Int {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            return Int(level)
        }
        return 1
    }
}
