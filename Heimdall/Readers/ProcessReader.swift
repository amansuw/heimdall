import Foundation

class ProcessReader {
    private var pidBuffer = [Int32](repeating: 0, count: 2048)
    private var nameBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))

    func readTopCPU(limit: Int = 8) -> [TopProcess] {
        readTop(limit: limit, sortBy: .cpu)
    }

    func readTopRAM(limit: Int = 8) -> [TopProcess] {
        readTop(limit: limit, sortBy: .ram)
    }

    func readTopDiskIO(limit: Int = 8) -> [TopProcess] {
        readTop(limit: limit, sortBy: .diskIO)
    }

    private enum SortMetric { case cpu, ram, diskIO }

    private func readTop(limit: Int, sortBy: SortMetric) -> [TopProcess] {
        let bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pidBuffer, Int32(MemoryLayout<Int32>.stride * pidBuffer.count))
        guard bufferSize > 0 else { return [] }
        let count = Int(bufferSize) / MemoryLayout<Int32>.stride

        var processes: [TopProcess] = []
        processes.reserveCapacity(min(count, 64))

        for i in 0..<count {
            let pid = pidBuffer[i]
            guard pid > 0 else { continue }

            var taskInfo = proc_taskinfo()
            let size = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, Int32(MemoryLayout<proc_taskinfo>.size))
            guard size == MemoryLayout<proc_taskinfo>.size else { continue }

            nameBuffer[0] = 0
            proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            let name = String(cString: nameBuffer)
            guard !name.isEmpty else { continue }

            let value: Double
            let formatted: String

            switch sortBy {
            case .cpu:
                let totalNs = taskInfo.pti_total_user + taskInfo.pti_total_system
                let totalSec = Double(totalNs) / 1_000_000_000
                let threadCount = taskInfo.pti_threadnum
                let recentCPU = min(Double(threadCount) * 5, totalSec)
                value = recentCPU
                formatted = String(format: "%.1f%%", recentCPU)
            case .ram:
                let bytes = UInt64(taskInfo.pti_resident_size)
                value = Double(bytes)
                formatted = ByteFormatter.format(bytes)
            case .diskIO:
                let totalIO = UInt64(taskInfo.pti_total_system) // approximation
                value = Double(totalIO)
                formatted = ByteFormatter.format(UInt64(value))
            }

            processes.append(TopProcess(id: pid, name: name, value: value, formattedValue: formatted))
        }

        processes.sort { $0.value > $1.value }
        return Array(processes.prefix(limit))
    }
}
