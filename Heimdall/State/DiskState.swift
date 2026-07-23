import Foundation

@Observable
class DiskState {
    var disks: [DiskInfo] = []
    var io = DiskIO()
    var topProcesses: [TopProcess] {
        guard let processHistory else { return [] }
        let _ = processHistory.revision
        return processHistory.topDiskIO(window: historyRange.window, limit: 8)
    }
    var historyRange: HistoryRange = .fiveMinutes
    var ioHistory = RingBuffer<DiskIOSnapshot>(capacity: 1800)
    var processHistory: ProcessHistory?

    var filteredHistory: [DiskIOSnapshot] {
        let all = ioHistory.toArray()
        let cutoff = Date().addingTimeInterval(-historyRange.window)
        return all.filter { $0.timestamp >= cutoff }
    }

    func applySpace(_ result: DiskSpaceResult) {
        disks = result.disks
    }

    func applyIO(_ result: DiskIOResult, recordHistory: Bool = true) {
        io = result.io
        if recordHistory {
            ioHistory.append(result.snapshot)
        }
    }
}
