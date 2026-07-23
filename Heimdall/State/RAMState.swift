import Foundation

@Observable
class RAMState {
    var memory = MemoryBreakdown()
    var topProcesses: [TopProcess] {
        guard let processHistory else { return [] }
        let _ = processHistory.revision
        return processHistory.topRAM(window: historyRange.window, limit: 8)
    }
    var historyRange: HistoryRange = .fiveMinutes
    var history = RingBuffer<RAMSnapshot>(capacity: 1800)
    var processHistory: ProcessHistory?

    var filteredHistory: [RAMSnapshot] {
        let all = history.toArray()
        let cutoff = Date().addingTimeInterval(-historyRange.window)
        return all.filter { $0.timestamp >= cutoff }
    }

    func apply(_ result: RAMReaderResult, recordHistory: Bool = true) {
        memory = result.memory
        if recordHistory {
            history.append(RAMSnapshot(
                timestamp: Date(),
                usagePercent: result.memory.usagePercent,
                appBytes: result.memory.app,
                wiredBytes: result.memory.wired,
                compressedBytes: result.memory.compressed
            ))
        }
    }
}
