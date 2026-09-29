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

    private var history = RingBuffer<PowerSnapshot>(capacity: chartHistoryCapacity)

    /// Snapshots inside the selected window. Recomputed only when the history
    /// grows or the range changes — never on a SwiftUI render pass.
    private(set) var filteredHistory: [PowerSnapshot] = []

    func apply(_ power: SoCPower, at now: Date = Date()) {
        latest = power
        history.append(PowerSnapshot(timestamp: now, cpu: power.cpu, gpu: power.gpu,
                                      ane: power.ane, system: power.system))
        // A late publication describes the whole gap since the counter last
        // moved, not the poll that happened to notice it. Paint that gap so a
        // minute at a few watts is a band, not one needle.
        paint(\.cpu, power.cpu, over: power.cpuWindow, ending: now)
        paint(\.gpu, power.gpu, over: power.gpuWindow, ending: now)
        paint(\.ane, power.ane, over: power.aneWindow, ending: now)
        refreshFilteredHistory()
    }

    private func paint(_ rail: WritableKeyPath<PowerSnapshot, Double?>, _ watts: Double?,
                       over window: TimeInterval, ending now: Date) {
        guard window > 0 else { return }
        let start = now.addingTimeInterval(-window)
        history.updateAll { snapshot in
            if snapshot.timestamp >= start { snapshot[keyPath: rail] = watts }
        }
    }

    private func refreshFilteredHistory() {
        filteredHistory = history.chartElements(since: Date().addingTimeInterval(-historyRange.window))
    }
}
