import Foundation

/// SoC power from IOReport. `latest` stays nil where IOReport is unavailable, and
/// views then hide power entirely rather than showing zeros.
@MainActor
@Observable
final class PowerState {
    private(set) var latest: SoCPower?

    var historyRange: HistoryRange = .fiveMinutes {
        didSet {
            guard oldValue != historyRange else { return }
            refreshFilteredHistory()
        }
    }

    private var history = RingBuffer<PowerSnapshot>(capacity: 1800)

    /// Snapshots inside the selected window. Recomputed only when the history
    /// grows or the range changes — never on a SwiftUI render pass.
    private(set) var filteredHistory: [PowerSnapshot] = []

    func apply(_ power: SoCPower) {
        latest = power
        history.append(PowerSnapshot(timestamp: Date(), cpu: power.cpu, gpu: power.gpu, ane: power.ane))
        refreshFilteredHistory()
    }

    private func refreshFilteredHistory() {
        filteredHistory = history.elements(since: Date().addingTimeInterval(-historyRange.window))
    }
}
