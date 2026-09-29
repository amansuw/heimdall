import Foundation

@MainActor
@Observable
class GPUState {
    var usage = GPUUsage()
    var topProcesses: [TopProcess] {
        guard let processHistory else { return [] }
        let _ = processHistory.revision
        return processHistory.topGPU(
            window: historyRange.window,
            limit: 8
        )
    }
    var historyRange: HistoryRange = .fiveMinutes {
        didSet {
            guard oldValue != historyRange else { return }
            refreshFilteredHistory()
        }
    }
    var history = RingBuffer<GPUSnapshot>(capacity: chartHistoryCapacity)
    var processHistory: ProcessHistory?

    /// Snapshots inside the selected window. Recomputed only when the history
    /// grows or the range changes — never on a SwiftUI render pass.
    private(set) var filteredHistory: [GPUSnapshot] = []

    func apply(_ result: GPUReaderResult, recordHistory: Bool = true) {
        usage = result.usage
        if recordHistory {
            history.append(GPUSnapshot(
                timestamp: Date(),
                utilization: result.usage.utilization,
                renderUtilization: result.usage.renderUtilization,
                tilerUtilization: result.usage.tilerUtilization
            ))
            refreshFilteredHistory()
        }
    }

    private func refreshFilteredHistory() {
        filteredHistory = history.chartElements(since: Date().addingTimeInterval(-historyRange.window))
    }
}
