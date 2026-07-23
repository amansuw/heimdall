import Foundation

@Observable
class NetworkState {
    var stats = NetworkStats()
    var topProcesses: [TopProcess] {
        guard let processHistory else { return [] }
        let _ = processHistory.revision
        return processHistory.topNetwork(window: historyRange.window, limit: 8)
    }
    var historyRange: HistoryRange = .fiveMinutes
    var history = RingBuffer<NetworkSnapshot>(capacity: 1800)
    var processHistory: ProcessHistory?

    var filteredHistory: [NetworkSnapshot] {
        let all = history.toArray()
        let cutoff = Date().addingTimeInterval(-historyRange.window)
        return all.filter { $0.timestamp >= cutoff }
    }

    func apply(_ result: NetworkReaderResult, recordHistory: Bool = true) {
        stats.downloadBytesPerSec = result.dlSpeed
        stats.uploadBytesPerSec = result.ulSpeed
        stats.totalDownload = result.totalIn
        stats.totalUpload = result.totalOut
        stats.activeInterface = result.activeIface
        if recordHistory {
            history.append(result.snapshot)
        }
    }
}
