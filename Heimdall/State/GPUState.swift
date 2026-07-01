import Foundation

@Observable
class GPUState {
    var usage = GPUUsage()
    var topProcesses: [TopProcess] {
        guard let processHistory else { return [] }
        let _ = processHistory.revision
        return processHistory.topCPU(
            window: historyRange.window,
            limit: 8,
            coreCount: ProcessInfo.processInfo.processorCount
        )
    }
    var historyRange: HistoryRange = .fiveMinutes
    var history = RingBuffer<GPUSnapshot>(capacity: 1800)
    var processHistory: ProcessHistory?

    var filteredHistory: [GPUSnapshot] {
        let all = history.toArray()
        let cutoff = Date().addingTimeInterval(-historyRange.window)
        return all.filter { $0.timestamp >= cutoff }
    }

    func apply(_ result: GPUReaderResult) {
        usage = result.usage
        history.append(GPUSnapshot(
            timestamp: Date(),
            utilization: result.usage.utilization,
            renderUtilization: result.usage.renderUtilization,
            tilerUtilization: result.usage.tilerUtilization
        ))
    }
}
