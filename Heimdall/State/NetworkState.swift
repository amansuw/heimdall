import Foundation

@Observable
class NetworkState {
    var stats = NetworkStats()
    var topProcesses: [TopProcess] = []
    var historyRange: HistoryRange = .max
    var history = RingBuffer<NetworkSnapshot>(capacity: 1800)

    var filteredHistory: [NetworkSnapshot] {
        let all = history.toArray()
        guard let window = historyRange.window else { return all }
        let cutoff = Date().addingTimeInterval(-window)
        return all.filter { $0.timestamp >= cutoff }
    }

    func apply(_ result: NetworkReaderResult) {
        stats.downloadBytesPerSec = result.dlSpeed
        stats.uploadBytesPerSec = result.ulSpeed
        stats.totalDownload = result.totalIn
        stats.totalUpload = result.totalOut
        stats.activeInterface = result.activeIface
        history.append(result.snapshot)
    }
}
