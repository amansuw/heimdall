import Foundation

@Observable
class CPUState {
    var usage = CPUUsage()
    var frequency = CPUFrequency()
    var loadAverage = LoadAverage()
    var uptime: TimeInterval = 0
    var topProcesses: [TopProcess] {
        guard let processHistory else { return [] }
        let _ = processHistory.revision
        return processHistory.topCPU(
            window: historyRange.window,
            limit: 8,
            coreCount: max(totalCores, 1)
        )
    }
    var historyRange: HistoryRange = .fiveMinutes {
        didSet {
            guard oldValue != historyRange else { return }
            refreshFilteredHistory()
        }
    }
    var history = RingBuffer<CPUSnapshot>(capacity: 1800)
    var processHistory: ProcessHistory?

    var totalCores: Int = 0
    var eCores: Int = 0
    var pCores: Int = 0

    var formattedUptime: String {
        UptimeFormatter.format(uptime)
    }

    /// Snapshots inside the selected window. Recomputed only when the history
    /// grows or the range changes — never on a SwiftUI render pass.
    private(set) var filteredHistory: [CPUSnapshot] = []

    func apply(_ result: CPUReaderResult, recordHistory: Bool = true) {
        usage = result.usage
        loadAverage = result.load
        uptime = result.uptime
        frequency = result.freq
        if recordHistory {
            history.append(result.snapshot)
            refreshFilteredHistory()
        }
    }

    func applyTopology(total: Int, e: Int, p: Int) {
        totalCores = total
        eCores = e
        pCores = p
    }

    private func refreshFilteredHistory() {
        filteredHistory = history.elements(since: Date().addingTimeInterval(-historyRange.window))
    }
}
