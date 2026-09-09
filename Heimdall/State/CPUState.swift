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
    var historyRange: HistoryRange = .fiveMinutes
    var history = RingBuffer<CPUSnapshot>(capacity: 1800)
    var processHistory: ProcessHistory?

    var totalCores: Int = 0
    /// Topology as discovered at launch, fastest cluster first.
    var clusters: [CPUCluster] = []

    /// "5 Performance + 6 Efficiency", or just "11 cores" when undifferentiated.
    var topologyDescription: String {
        let named = clusters.filter { !$0.letter.isEmpty }
        guard !named.isEmpty else { return "\(totalCores) cores" }
        let parts = named.map { "\($0.coreIndices.count) \($0.name)" }
        return "\(totalCores) cores (\(parts.joined(separator: " + ")))"
    }

    var formattedUptime: String {
        UptimeFormatter.format(uptime)
    }

    var filteredHistory: [CPUSnapshot] {
        let all = history.toArray()
        let cutoff = Date().addingTimeInterval(-historyRange.window)
        return all.filter { $0.timestamp >= cutoff }
    }

    func apply(_ result: CPUReaderResult, recordHistory: Bool = true) {
        usage = result.usage
        loadAverage = result.load
        uptime = result.uptime
        frequency = result.freq
        if recordHistory {
            history.append(result.snapshot)
        }
    }

    func applyTopology(total: Int, clusters: [CPUCluster]) {
        totalCores = total
        self.clusters = clusters
    }
}
