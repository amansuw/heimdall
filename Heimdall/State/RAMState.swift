import Foundation

@Observable
class RAMState {
    var memory = MemoryBreakdown()
    var topProcesses: [TopProcess] = []
    var historyRange: HistoryRange = .max
    var history = RingBuffer<RAMSnapshot>(capacity: 1800)

    var filteredHistory: [RAMSnapshot] {
        let all = history.toArray()
        guard let window = historyRange.window else { return all }
        let cutoff = Date().addingTimeInterval(-window)
        return all.filter { $0.timestamp >= cutoff }
    }

    func apply(_ result: RAMReaderResult) {
        memory = result.memory
        history.append(RAMSnapshot(
            timestamp: Date(),
            usagePercent: result.memory.usagePercent,
            appBytes: result.memory.app,
            wiredBytes: result.memory.wired,
            compressedBytes: result.memory.compressed
        ))
    }
}
