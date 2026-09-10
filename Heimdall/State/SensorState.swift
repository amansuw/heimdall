import Foundation

enum HistoryRange: String, CaseIterable, Identifiable, Sendable {
    case oneMinute = "1m"
    case fiveMinutes = "5m"
    case thirtyMinutes = "30m"
    case sixtyMinutes = "60m"

    var id: String { rawValue }

    var window: TimeInterval {
        switch self {
        case .oneMinute: return 60
        case .fiveMinutes: return 5 * 60
        case .thirtyMinutes: return 30 * 60
        case .sixtyMinutes: return 60 * 60
        }
    }
}

@Observable
class SensorState {
    var readings: [SensorReading] = []
    var temperatureReadings: [SensorReading] = []
    var voltageReadings: [SensorReading] = []
    var currentReadings: [SensorReading] = []
    var powerReadings: [SensorReading] = []
    var isMonitoring = false
    var isDiscovering = true
    var historyRange: HistoryRange = .fiveMinutes {
        didSet {
            guard oldValue != historyRange else { return }
            refreshFilteredHistory()
        }
    }
    var temperatureHistory = RingBuffer<TemperatureSnapshot>(capacity: 900)

    // Aggregates below are derived once per sensor tick (in `apply`) from the
    // sensor roles classified at read time, instead of re-scanning and
    // re-prefix-matching the whole reading array on every SwiftUI render.

    private(set) var averageCPUTemp: Double = 0
    private(set) var hottestCPUTemp: Double = 0
    private(set) var averageGPUTemp: Double = 0
    private(set) var hottestGPUTemp: Double = 0

    /// Number of CPU-die temperature sensors currently reporting.
    private(set) var cpuCoreCount: Int = 0
    /// Number of GPU-die temperature sensors currently reporting.
    private(set) var gpuCoreCount: Int = 0

    private(set) var dashboardCPUTemps: [SensorReading] = []
    private(set) var dashboardGPUTemps: [SensorReading] = []
    private(set) var dashboardSystemTemps: [SensorReading] = []

    /// Snapshots inside the selected window. Recomputed only when the history
    /// grows or the range changes — never on a SwiftUI render pass.
    private(set) var filteredHistory: [TemperatureSnapshot] = []

    func apply(_ result: SensorReaderResult, recordHistory: Bool = true) {
        readings = result.all
        temperatureReadings = result.temp
        voltageReadings = result.volt
        currentReadings = result.curr
        powerReadings = result.pow

        averageCPUTemp = result.snapshot.avgCPU
        hottestCPUTemp = result.snapshot.maxCPU
        averageGPUTemp = result.snapshot.avgGPU
        hottestGPUTemp = result.snapshot.maxGPU
        cpuCoreCount = result.cpuTemps.count
        gpuCoreCount = result.gpuTemps.count
        dashboardCPUTemps = result.cpuTemps
        dashboardGPUTemps = result.gpuTemps.count > 8 ? Array(result.gpuTemps.prefix(8)) : result.gpuTemps
        dashboardSystemTemps = result.systemTemps

        isMonitoring = true
        if recordHistory {
            temperatureHistory.append(result.snapshot)
            refreshFilteredHistory()
        }
    }

    private func refreshFilteredHistory() {
        filteredHistory = temperatureHistory.elements(since: Date().addingTimeInterval(-historyRange.window))
    }
}
