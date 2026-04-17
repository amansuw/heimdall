import Foundation

@Observable
class GPUState {
    var usage = GPUUsage()
    var topProcesses: [TopProcess] = []
    var historyRange: HistoryRange = .max
    var history = RingBuffer<GPUSnapshot>(capacity: 1800)

    var filteredHistory: [GPUSnapshot] {
        let all = history.toArray()
        guard let window = historyRange.window else { return all }
        let cutoff = Date().addingTimeInterval(-window)
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
