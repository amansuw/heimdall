import Foundation

@MainActor
@Observable
class DiskState {
    var disks: [DiskInfo] = []
    var io = DiskIO()
    var topProcesses: [TopProcess] {
        guard let processHistory else { return [] }
        let _ = processHistory.revision
        return processHistory.topDiskIO(window: historyRange.window, limit: 8)
    }
    var historyRange: HistoryRange = .fiveMinutes {
        didSet {
            guard oldValue != historyRange else { return }
            refreshFilteredHistory()
        }
    }
    var ioHistory = RingBuffer<DiskIOSnapshot>(capacity: chartHistoryCapacity)
    var processHistory: ProcessHistory?

    /// Snapshots inside the selected window. Recomputed only when the history
    /// grows or the range changes — never on a SwiftUI render pass.
    private(set) var filteredHistory: [DiskIOSnapshot] = []

    func applySpace(_ result: DiskSpaceResult) {
        disks = result.disks
    }

    func applyIO(_ result: DiskIOResult, recordHistory: Bool = true) {
        io = result.io
        if recordHistory {
            ioHistory.append(result.snapshot)
            refreshFilteredHistory()
        }
    }

    private func refreshFilteredHistory() {
        filteredHistory = ioHistory.chartElements(since: Date().addingTimeInterval(-historyRange.window))
    }
}
