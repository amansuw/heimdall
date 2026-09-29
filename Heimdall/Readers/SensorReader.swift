import Foundation

struct SensorReaderResult: Sendable {
    let all: [SensorReading]
    let temp: [SensorReading]
    let volt: [SensorReading]
    let curr: [SensorReading]
    let pow: [SensorReading]
    /// CPU die temperatures, sorted by key. Derived here so the UI never has to
    /// re-scan `temp` for them.
    let cpuTemps: [SensorReading]
    /// GPU die temperatures, sorted by key.
    let gpuTemps: [SensorReading]
    /// Chassis temperatures shown on the dashboard, sorted by key.
    let systemTemps: [SensorReading]
    let snapshot: TemperatureSnapshot
}

class SensorReader {
    private let smc = SMCKit.shared
    private(set) var discoveredSensors: [(key: String, name: String, category: SensorCategory)] = []
    private(set) var isDiscovering = true
    /// Last live reading of each die sensor. A powered-down sensor keeps it for
    /// `dieHoldFor`, so the averages do not swing between the die and the
    /// always-on sensors every time the GPU wakes for a frame.
    private var lastLiveDie: [String: (value: Double, at: Date)] = [:]
    static let dieHoldFor: TimeInterval = 60

    func discoverSensors() {
        isDiscovering = true

        var sensors: [(key: String, name: String, category: SensorCategory)] = []
        var seenKeys = Set<String>()

        let keyCount = smc.getKeyCount()

        for i in 0..<keyCount {
            guard let key = smc.getKeyAtIndex(i) else { continue }
            guard !seenKeys.contains(key) else { continue }
            guard let category = SensorLookup.category(for: key) else { continue }
            // Fan keys (F<n>Ac/Mn/Mx/Tg) are owned by FanController, which reads
            // them on its own cadence. Polling them here every tick only to drop
            // the readings is wasted SMC traffic.
            guard category != .fan else { continue }
            guard let val = smc.readKey(key) else { continue }
            guard SensorLookup.isValidDataType(val.dataType, for: category) else { continue }

            let role = SensorRole.classify(key: key, category: category)
            let hasNonZero = val.bytes.prefix(Int(val.dataSize)).contains(where: { $0 != 0 })
            let isDie = role == .cpuTemp || role == .gpuTemp
            guard hasNonZero || isDie else { continue }

            // A die sensor on a sleeping cluster is still a sensor. Skipping it
            // here meant a launch while the GPU slept found 6 GPU sensors, not 38.
            guard let decoded = smc.decodeValue(val), decoded.isFinite,
                  SensorLookup.isReasonableValue(decoded, for: category)
                    || SensorLookup.isPoweredDownDieReading(decoded, role: role) else { continue }

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

        var all: [SensorReading] = []
        var temp: [SensorReading] = []
        var volt: [SensorReading] = []
        var curr: [SensorReading] = []
        var pow: [SensorReading] = []
        var cpuTemps: [SensorReading] = []
        var gpuTemps: [SensorReading] = []
        var systemTemps: [SensorReading] = []
        all.reserveCapacity(discoveredSensors.count)

        var cpuTempSum = 0.0, cpuTempMax = 0.0
        var gpuTempSum = 0.0, gpuTempMax = 0.0

        let now = Date()
        for sensor in discoveredSensors {
            guard let val = smc.readKey(sensor.key),
                  var value = smc.decodeValue(val), value.isFinite else { continue }
            let role = SensorRole.classify(key: sensor.key, category: sensor.category)
            if SensorLookup.isPoweredDownDieReading(value, role: role) {
                guard let held = lastLiveDie[sensor.key],
                      now.timeIntervalSince(held.at) <= Self.dieHoldFor else { continue }
                value = held.value
            } else {
                guard SensorLookup.isReasonableValue(value, for: sensor.category) else { continue }
                if role == .cpuTemp || role == .gpuTemp { lastLiveDie[sensor.key] = (value, now) }
            }

            let reading = SensorReading(id: sensor.key, name: sensor.name, category: sensor.category, value: value, key: sensor.key)
            all.append(reading)

            switch sensor.category {
            case .temperature:
                temp.append(reading)
                switch reading.role {
                case .cpuTemp:
                    cpuTemps.append(reading)
                    cpuTempSum += value
                    cpuTempMax = max(cpuTempMax, value)
                case .gpuTemp:
                    gpuTemps.append(reading)
                    gpuTempSum += value
                    gpuTempMax = max(gpuTempMax, value)
                case .systemTemp:
                    systemTemps.append(reading)
                case .other:
                    break
                }
            case .voltage: volt.append(reading)
            case .current: curr.append(reading)
            case .power: pow.append(reading)
            case .fan: break
            }
        }

        // A tick with no matching sensors is a MISSING sample, not 0 — recording
        // 0 would drag the chart's y-domain down and draw a false dip to zero.
        // `discoveredSensors` is already key-sorted within a category, so the
        // per-role arrays come out sorted by key for free.
        let avgCPU: Double? = cpuTemps.isEmpty ? nil : cpuTempSum / Double(cpuTemps.count)
        let avgGPU: Double? = gpuTemps.isEmpty ? nil : gpuTempSum / Double(gpuTemps.count)
        let maxCPU: Double? = cpuTemps.isEmpty ? nil : cpuTempMax
        let maxGPU: Double? = gpuTemps.isEmpty ? nil : gpuTempMax

        return SensorReaderResult(
            all: all, temp: temp, volt: volt, curr: curr, pow: pow,
            cpuTemps: cpuTemps, gpuTemps: gpuTemps, systemTemps: systemTemps,
            snapshot: TemperatureSnapshot(timestamp: Date(), avgCPU: avgCPU, avgGPU: avgGPU, maxCPU: maxCPU, maxGPU: maxGPU)
        )
    }

    // MARK: - Curated aggregates

    func cpuTemps(from readings: [SensorReading]) -> [SensorReading] {
        readings.filter(\.isCPUTemp)
    }

    func gpuTemps(from readings: [SensorReading]) -> [SensorReading] {
        readings.filter(\.isGPUTemp)
    }
}
