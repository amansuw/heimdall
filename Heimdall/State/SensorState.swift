import Foundation

enum HistoryRange: String, CaseIterable, Identifiable, Sendable {
    case oneMinute = "1m"
    case fiveMinutes = "5m"
    case thirtyMinutes = "30m"
    case sixtyMinutes = "60m"
    case max = "Max"

    var id: String { rawValue }

    var window: TimeInterval? {
        switch self {
        case .oneMinute: return 60
        case .fiveMinutes: return 5 * 60
        case .thirtyMinutes: return 30 * 60
        case .sixtyMinutes: return 60 * 60
        case .max: return nil
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
    var historyRange: HistoryRange = .max
    var temperatureHistory = RingBuffer<TemperatureSnapshot>(capacity: 3600)

    var averageCPUTemp: Double {
        let temps = temperatureReadings.filter { $0.key.hasPrefix("TC") || $0.key.hasPrefix("Tc") }
        guard !temps.isEmpty else { return 0 }
        return temps.map(\.value).reduce(0, +) / Double(temps.count)
    }

    var hottestCPUTemp: Double {
        temperatureReadings.filter { $0.key.hasPrefix("TC") || $0.key.hasPrefix("Tc") }.map(\.value).max() ?? 0
    }

    var averageGPUTemp: Double {
        let temps = temperatureReadings.filter { $0.key.hasPrefix("TG") || $0.key.hasPrefix("Tg") }
        guard !temps.isEmpty else { return 0 }
        return temps.map(\.value).reduce(0, +) / Double(temps.count)
    }

    var hottestGPUTemp: Double {
        temperatureReadings.filter { $0.key.hasPrefix("TG") || $0.key.hasPrefix("Tg") }.map(\.value).max() ?? 0
    }

    var cpuCoreCount: Int {
        temperatureReadings.filter { $0.key.hasPrefix("TC") || $0.key.hasPrefix("Tc") }.count
    }

    var gpuCoreCount: Int {
        temperatureReadings.filter { $0.key.hasPrefix("TG") || $0.key.hasPrefix("Tg") }.count
    }

    var dashboardCPUTemps: [SensorReading] {
        temperatureReadings.filter { $0.key.hasPrefix("TC") || $0.key.hasPrefix("Tc") }.sorted { $0.key < $1.key }
    }

    var dashboardGPUTemps: [SensorReading] {
        let all = temperatureReadings.filter { $0.key.hasPrefix("TG") || $0.key.hasPrefix("Tg") }.sorted { $0.key < $1.key }
        return Array(all.prefix(8))
    }

    var dashboardSystemTemps: [SensorReading] {
        temperatureReadings.filter {
            $0.key.hasPrefix("TH") || $0.key.hasPrefix("TB") || $0.key.hasPrefix("Ta") || $0.key.hasPrefix("TW")
        }.sorted { $0.key < $1.key }
    }

    var filteredHistory: [TemperatureSnapshot] {
        let all = temperatureHistory.toArray()
        guard let window = historyRange.window else { return all }
        let cutoff = Date().addingTimeInterval(-window)
        return all.filter { $0.timestamp >= cutoff }
    }

    func apply(_ result: SensorReaderResult) {
        readings = result.all
        temperatureReadings = result.temp
        voltageReadings = result.volt
        currentReadings = result.curr
        powerReadings = result.pow
        isMonitoring = true
        temperatureHistory.append(result.snapshot)
    }
}
