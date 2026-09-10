import Foundation

@MainActor
@Observable
class RAMState {
    var memory = MemoryBreakdown()
    var topProcesses: [TopProcess] {
        guard let processHistory else { return [] }
        let _ = processHistory.revision
        return processHistory.topRAM(window: historyRange.window, limit: 8)
    }
    var historyRange: HistoryRange = .fiveMinutes {
        didSet {
            guard oldValue != historyRange else { return }
            refreshFilteredHistory()
        }
    }
    var history = RingBuffer<RAMSnapshot>(capacity: 1800)
    var processHistory: ProcessHistory?

    /// Snapshots inside the selected window. Recomputed only when the history
    /// grows or the range changes — never on a SwiftUI render pass.
    private(set) var filteredHistory: [RAMSnapshot] = []

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
            refreshFilteredHistory()
        }
    }

    private func refreshFilteredHistory() {
        filteredHistory = history.elements(since: Date().addingTimeInterval(-historyRange.window))
    }
}
