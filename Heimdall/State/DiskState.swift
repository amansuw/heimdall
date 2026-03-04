import Foundation

@Observable
class DiskState {
    var disks: [DiskInfo] = []
    var io = DiskIO()
    var topProcesses: [TopProcess] = []
    var historyRange: HistoryRange = .max
    var ioHistory = RingBuffer<DiskIOSnapshot>(capacity: 1800)

    var filteredHistory: [DiskIOSnapshot] {
        let all = ioHistory.toArray()
        guard let window = historyRange.window else { return all }
        let cutoff = Date().addingTimeInterval(-window)
        return all.filter { $0.timestamp >= cutoff }
    }

    func applySpace(_ result: DiskSpaceResult) {
        disks = result.disks
    }

    func applyIO(_ result: DiskIOResult) {
        io = result.io
        ioHistory.append(result.snapshot)
    }
}
