import Foundation
import IOKit
import IOKit.ps

struct BatteryReaderResult: Sendable {
    let battery: BatteryInfo
}

class BatteryReader {
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

        if let cycles = dict["CycleCount"] as? Int { info.cycleCount = cycles }
        if let designCap = dict["DesignCapacity"] as? Int { info.designCapacity = designCap }

        // Try to get max capacity from BatteryData (nested) first, then fall back to AppleRawMaxCapacity
        var maxCap = 0
        if let batteryData = dict["BatteryData"] as? [String: Any],
           let fcc = batteryData["FccComp1"] as? Int, fcc > 0 {
            maxCap = fcc
        } else if let rawMax = dict["AppleRawMaxCapacity"] as? Int, rawMax > 0 {
            maxCap = rawMax
        }
        if maxCap > 0 {
            info.maxCapacity = maxCap
            if info.designCapacity > 0 {
                info.healthPercent = Double(maxCap) / Double(info.designCapacity) * 100
            }
        }

        if let temp = dict["Temperature"] as? Int { info.temperature = Double(temp) / 100.0 }
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
}
