import Foundation

@Observable
class CPUState {
    var usage = CPUUsage()
    var frequency = CPUFrequency()
    var loadAverage = LoadAverage()
    var uptime: TimeInterval = 0
    var topProcesses: [TopProcess] = []
    var historyRange: HistoryRange = .max
    var history = RingBuffer<CPUSnapshot>(capacity: 1800)

    var totalCores: Int = 0
    var eCores: Int = 0
    var pCores: Int = 0

    var formattedUptime: String {
        UptimeFormatter.format(uptime)
    }

    var filteredHistory: [CPUSnapshot] {
        let all = history.toArray()
        guard let window = historyRange.window else { return all }
        let cutoff = Date().addingTimeInterval(-window)
        return all.filter { $0.timestamp >= cutoff }
    }

    func apply(_ result: CPUReaderResult) {
        usage = result.usage
        loadAverage = result.load
        uptime = result.uptime
        frequency = result.freq
        history.append(result.snapshot)
    }

    func applyTopology(total: Int, e: Int, p: Int) {
        totalCores = total
        eCores = e
        pCores = p
    }
}
