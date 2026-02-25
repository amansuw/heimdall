import Foundation

struct SensorReaderResult: Sendable {
    let all: [SensorReading]
    let temp: [SensorReading]
    let volt: [SensorReading]
    let curr: [SensorReading]
    let pow: [SensorReading]
    let snapshot: TemperatureSnapshot
}

class SensorReader {
    private let smc = SMCKit.shared
    private(set) var discoveredSensors: [(key: String, name: String, category: SensorCategory)] = []
    private(set) var isDiscovering = true

    private var scratchAll: [SensorReading] = []
    private var scratchTemp: [SensorReading] = []
    private var scratchVolt: [SensorReading] = []
    private var scratchCurr: [SensorReading] = []
    private var scratchPow: [SensorReading] = []

    func discoverSensors() {
        isDiscovering = true

        var sensors: [(key: String, name: String, category: SensorCategory)] = []
        var seenKeys = Set<String>()

        let keyCount = smc.getKeyCount()

        for i in 0..<keyCount {
            guard let key = smc.getKeyAtIndex(i) else { continue }
            guard !seenKeys.contains(key) else { continue }
            guard let category = SensorLookup.category(for: key) else { continue }
            guard let val = smc.readKey(key) else { continue }
            guard SensorLookup.isValidDataType(val.dataType, for: category) else { continue }

            let hasNonZero = val.bytes.prefix(Int(val.dataSize)).contains(where: { $0 != 0 })
            guard hasNonZero else { continue }

            guard let decoded = smc.decodeValue(val),
                  decoded.isFinite,
                  SensorLookup.isReasonableValue(decoded, for: category) else { continue }

            let name = SensorLookup.name(for: key)
            sensors.append((key: key, name: name, category: category))
            seenKeys.insert(key)
        }

        sensors.sort { a, b in
            if a.category.rawValue != b.category.rawValue {
                return a.category.rawValue < b.category.rawValue
            }
            return a.key < b.key
        }

        discoveredSensors = sensors
        isDiscovering = false
    }

    func read() -> SensorReaderResult? {
        guard !discoveredSensors.isEmpty else { return nil }

        scratchAll.removeAll(keepingCapacity: true)
        scratchTemp.removeAll(keepingCapacity: true)
        scratchVolt.removeAll(keepingCapacity: true)
        scratchCurr.removeAll(keepingCapacity: true)
        scratchPow.removeAll(keepingCapacity: true)

        var cpuTempSum = 0.0, cpuTempMax = 0.0, cpuTempCount = 0
        var gpuTempSum = 0.0, gpuTempMax = 0.0, gpuTempCount = 0

        for sensor in discoveredSensors {
            guard let val = smc.readKey(sensor.key) else { continue }
            guard let value = smc.decodeValue(val),
                  value.isFinite,
                  SensorLookup.isReasonableValue(value, for: sensor.category) else { continue }

            let reading = SensorReading(id: sensor.key, name: sensor.name, category: sensor.category, value: value, key: sensor.key)
            scratchAll.append(reading)

            switch sensor.category {
            case .temperature:
                scratchTemp.append(reading)
                let k = sensor.key
                if k.hasPrefix("TC") || k.hasPrefix("Tc") {
                    cpuTempSum += value; cpuTempMax = max(cpuTempMax, value); cpuTempCount += 1
                } else if k.hasPrefix("TG") || k.hasPrefix("Tg") {
                    gpuTempSum += value; gpuTempMax = max(gpuTempMax, value); gpuTempCount += 1
                }
            case .voltage: scratchVolt.append(reading)
            case .current: scratchCurr.append(reading)
            case .power: scratchPow.append(reading)
            case .fan: break
            }
        }

        let avgCPU = cpuTempCount > 0 ? cpuTempSum / Double(cpuTempCount) : 0
        let avgGPU = gpuTempCount > 0 ? gpuTempSum / Double(gpuTempCount) : 0

        return SensorReaderResult(
            all: scratchAll, temp: scratchTemp, volt: scratchVolt, curr: scratchCurr, pow: scratchPow,
            snapshot: TemperatureSnapshot(timestamp: Date(), avgCPU: avgCPU, avgGPU: avgGPU, maxCPU: cpuTempMax, maxGPU: gpuTempMax)
        )
    }

    // MARK: - Curated aggregates

    func cpuTemps(from readings: [SensorReading]) -> [SensorReading] {
        readings.filter { $0.key.hasPrefix("TC") || $0.key.hasPrefix("Tc") }
    }

    func gpuTemps(from readings: [SensorReading]) -> [SensorReading] {
        readings.filter { $0.key.hasPrefix("TG") || $0.key.hasPrefix("Tg") }
    }
}
