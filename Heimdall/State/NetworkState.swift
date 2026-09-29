import Foundation

@MainActor
@Observable
class NetworkState {
    var stats = NetworkStats()
    var topProcesses: [TopProcess] {
        guard let processHistory else { return [] }
        let _ = processHistory.revision
        return processHistory.topNetwork(window: historyRange.window, limit: 8)
    }
    var historyRange: HistoryRange = .fiveMinutes {
        didSet {
            guard oldValue != historyRange else { return }
            refreshFilteredHistory()
        }
    }
    var history = RingBuffer<NetworkSnapshot>(capacity: chartHistoryCapacity)
    var processHistory: ProcessHistory?

    /// Snapshots inside the selected window. Recomputed only when the history
    /// grows or the range changes — never on a SwiftUI render pass.
    private(set) var filteredHistory: [NetworkSnapshot] = []

    func apply(_ result: NetworkReaderResult, recordHistory: Bool = true) {
        stats.downloadBytesPerSec = result.dlSpeed
        stats.uploadBytesPerSec = result.ulSpeed
        stats.totalDownload = result.totalIn
        stats.totalUpload = result.totalOut
        stats.activeInterface = result.activeIface
        if recordHistory {
            history.append(result.snapshot)
            refreshFilteredHistory()
        }
    }

    private func refreshFilteredHistory() {
        filteredHistory = history.chartElements(since: Date().addingTimeInterval(-historyRange.window))
    }
}
