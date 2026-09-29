import Foundation
import IOKit
import IOKit.ps

struct BatteryReaderResult: Sendable {
    let battery: BatteryInfo
}

class BatteryReader {
    /// Apple's "Maximum Capacity" percentage and when it was read. It moves a
    /// point every few weeks, so it is fetched once an hour, not every tick.
    private var maximumCapacity: (percent: Double?, readAt: Date)?

    func read() -> BatteryReaderResult {
        var info = BatteryInfo()

        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sourcesRef = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue()
        guard let sources = sourcesRef as CFArray? as? [CFTypeRef], !sources.isEmpty else {
            return BatteryReaderResult(battery: info)
        }

        guard let source = sources.first,
              let desc = IOPSGetPowerSourceDescription(snapshot, source).takeUnretainedValue() as? [String: Any] else {
            return BatteryReaderResult(battery: info)
        }

        info.hasBattery = true

        if let current = desc[kIOPSCurrentCapacityKey] as? Int,
           let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 {
            info.level = Double(current) / Double(max) * 100
            info.currentCapacity = current
            info.maxCapacity = max
        }

        if let isCharging = desc[kIOPSIsChargingKey] as? Bool {
            info.isCharging = isCharging
        }

        if let source = desc[kIOPSPowerSourceStateKey] as? String {
            info.isPluggedIn = source == kIOPSACPowerValue
            info.source = info.isPluggedIn ? "AC Power" : "Battery"
        }

        if let timeRemaining = desc[kIOPSTimeToEmptyKey] as? Int {
            info.timeRemaining = timeRemaining
        }

        // IOKit registry for extended battery info
        readIOKitBatteryInfo(&info)

        return BatteryReaderResult(battery: info)
    }

    private func readIOKitBatteryInfo(_ info: inout BatteryInfo) {
        let matching = IOServiceMatching("AppleSmartBattery")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else { return }
        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return }

        // Recent macOS releases on Apple silicon report the mAh figures only
        // inside BatteryData. Top level first, then there.
        let batteryData = dict["BatteryData"] as? [String: Any] ?? [:]
        func capacity(_ key: String) -> Int? {
            let value = (dict[key] as? Int) ?? (batteryData[key] as? Int)
            return value.flatMap { $0 > 0 ? $0 : nil }
        }

        if let cycles = dict["CycleCount"] as? Int { info.cycleCount = cycles }
        if let designCap = capacity("DesignCapacity") { info.designCapacity = designCap }

        if let rawCurrent = capacity("AppleRawCurrentCapacity") ?? capacity("RemainingCapacity") {
            info.currentCapacity = rawCurrent
        }

        let fullChargeCap = capacity("NominalChargeCapacity")
            ?? capacity("AppleRawMaxCapacity")
            ?? capacity("FccComp2")
            ?? capacity("FccComp1")
            ?? 0

        if fullChargeCap > 0 {
            info.maxCapacity = fullChargeCap
            if info.designCapacity > 0 {
                info.healthPercent = min(100, Double(fullChargeCap) / Double(info.designCapacity) * 100)
            }
        }

        // System Information's "Maximum Capacity" is not nominal / design: on an
        // M3 Max with 183 cycles that ratio is 93% while Apple reports 100%.
        // Show Apple's figure when it is available, the ratio otherwise.
        if let percent = appleMaximumCapacity() {
            info.healthPercent = percent
        }

        if let temp = dict["Temperature"] as? Int {
            info.temperature = Double(temp) / 100.0
        } else {
            // The registry stopped carrying Temperature alongside the mAh keys.
            // The SMC still has the pack's own sensors.
            let packTemps = ["TB0T", "TB1T", "TB2T"].compactMap { SMCKit.shared.readFloat($0) }
                .filter { $0.isFinite && $0 > 0 && $0 < 100 }
            if let hottest = packTemps.max() { info.temperature = hottest }
        }
        if let voltage = dict["Voltage"] as? Int { info.voltage = Double(voltage) / 1000.0 }
        if let amperage = dict["InstantAmperage"] as? Int {
            let amps = Double(amperage) / 1000.0
            info.power = abs(amps * info.voltage)
        }

        if let adapterInfo = dict["AdapterInfo"] as? [String: Any] {
            if let watts = adapterInfo["Watts"] as? Int { info.adapterWatts = watts }
            if let current = adapterInfo["Current"] as? Int { info.adapterCurrent = current }
            if let voltage = adapterInfo["Voltage"] as? Int { info.adapterVoltage = voltage }
        }
    }

    private func appleMaximumCapacity() -> Double? {
        if let cached = maximumCapacity, Date().timeIntervalSince(cached.readAt) < 3600 {
            return cached.percent
        }
        let percent = Self.readMaximumCapacity()
        maximumCapacity = (percent, Date())
        return percent
    }

    /// "Maximum Capacity" as System Information shows it. No public API or
    /// registry key carries it, so this asks system_profiler (about 80ms).
    private static func readMaximumCapacity() -> Double? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPPowerDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }

        let watchdog = DispatchWorkItem { [process] in
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return parseMaximumCapacity(data)
    }

    static func parseMaximumCapacity(_ data: Data) -> Double? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["SPPowerDataType"] as? [[String: Any]] else { return nil }
        for item in items {
            guard let health = item["sppower_battery_health_info"] as? [String: Any],
                  let text = health["sppower_battery_health_maximum_capacity"] as? String,
                  let percent = Double(text.trimmingCharacters(in: CharacterSet(charactersIn: "% "))),
                  percent > 0
            else { continue }
            return min(percent, 100)
        }
        return nil
    }
}
