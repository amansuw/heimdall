import Foundation
import IOKit

/// Collects everything needed to reproduce and fix a hardware-specific problem on
/// a Mac the developer does not own: CPU topology, the device-tree cluster map,
/// GPU core count, fan inventory, and a full SMC key dump with RAW BYTES.
///
/// Raw bytes matter. Decoded values only prove what the current decoder does with
/// them; the bytes let a fixture replay the same hardware and test the decoder
/// itself. Every SMC type Heimdall has got wrong so far was a decoding bug, not a
/// reading bug.
enum Diagnostics {

    static func report() -> String {
        var out: [String] = []
        out.append("Heimdall diagnostics")
        out.append("generated: \(ISO8601DateFormatter().string(from: Date()))")
        out.append("app version: \(appVersion())")
        out.append("")
        out.append(contentsOf: systemSection())
        out.append("")
        out.append(contentsOf: cpuSection())
        out.append("")
        out.append(contentsOf: gpuSection())
        out.append("")
        out.append(contentsOf: helperSection())
        out.append("")
        out.append(contentsOf: smcSection())
        return out.joined(separator: "\n")
    }

    // MARK: - Sections

    private static func systemSection() -> [String] {
        [
            "## System",
            "model:      \(sysctlString("hw.model"))",
            "chip:       \(sysctlString("machdep.cpu.brand_string"))",
            "macOS:      \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "memory:     \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB",
        ]
    }

    private static func cpuSection() -> [String] {
        var lines = ["## CPU topology"]
        lines.append("logicalcpu:   \(sysctlInt("hw.logicalcpu") ?? -1)")
        lines.append("physicalcpu:  \(sysctlInt("hw.physicalcpu") ?? -1)")

        let levels = sysctlInt("hw.nperflevels") ?? 0
        lines.append("nperflevels:  \(levels)")
        for index in 0..<max(levels, 0) {
            let name = sysctlString("hw.perflevel\(index).name")
            let logical = sysctlInt("hw.perflevel\(index).logicalcpu") ?? -1
            let physical = sysctlInt("hw.perflevel\(index).physicalcpu") ?? -1
            lines.append("  perflevel\(index): name=\(name) logical=\(logical) physical=\(physical)")
        }

        // The authoritative core -> cluster mapping. Index ordering is NOT reliable:
        // on an M3 Pro the efficiency cores occupy the low indices.
        lines.append("device-tree cluster map (logical-cpu-id -> cluster-type):")
        let map = clusterMap()
        if map.isEmpty {
            lines.append("  (unavailable — Intel, or the device tree could not be read)")
        } else {
            for id in map.keys.sorted() { lines.append("  cpu\(id) -> \(map[id]!)") }
        }
        return lines
    }

    private static func gpuSection() -> [String] {
        var lines = ["## GPU"]
        lines.append("gpu-core-count: \(registryInt("gpu-core-count").map(String.init) ?? "unavailable")")
        lines.append("ANE present:    \(aneIsPresent() ? "yes" : "no")")
        lines.append("IOReport energy: \(PowerReader().isAvailable ? "available" : "unavailable")")
        return lines
    }

    /// Most "fan control does nothing" reports come down to the helper: missing,
    /// from another build, or not where it must be.
    private static func helperSection() -> [String] {
        let appHash = CodeIdentity.currentCDHash()
        let record = HelperInstaller.Record.load()
        let copy: String
        if !FileManager.default.fileExists(atPath: HelperInstaller.executablePath) {
            copy = "absent"
        } else {
            copy = HelperInstaller.isRootOnly(HelperInstaller.executablePath) ? "present, root-only" : "present, NOT root-only"
        }
        return [
            "## Fan helper",
            "app cdhash:         \(appHash ?? "unsigned")",
            "installed record:   \(record.map { "\($0.versionTag), cdhash \($0.cdhash)" } ?? "none")",
            "matches this build: \(HelperInstaller.isInstalled(forCDHash: appHash, record: record) ? "yes" : "no")",
            "helper copy:        \(copy)",
            "socket:             \(FileManager.default.fileExists(atPath: SMCDaemon.socketPath) ? "present" : "absent")",
        ]
    }

    private static func smcSection() -> [String] {
        let smc = SMCKit.shared
        var lines = ["## SMC keys"]

        let fanCount = smc.getNumberOfFans()
        lines.append("FNum (fan count): \(fanCount)")
        lines.append("")
        lines.append("key   type  size  raw bytes                        decoded")
        lines.append(String(repeating: "-", count: 72))

        for key in smc.getAllKeys() {
            guard let value = smc.readKey(key) else { continue }
            let bytes = value.bytes.prefix(Int(value.dataSize))
                .map { String(format: "%02X", $0) }
                .joined(separator: " ")
            let decoded = smc.decodeValue(value).map { String(format: "%.4f", $0) } ?? "-"
            lines.append(String(format: "%-5@ %-5@ %-5d %-32@ %@",
                                key as NSString,
                                value.dataType.trimmingCharacters(in: .whitespaces) as NSString,
                                value.dataSize,
                                bytes as NSString,
                                decoded as NSString))
        }
        return lines
    }

    // MARK: - Sources

    private static func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unavailable" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "unavailable" }
        return String(cString: buf)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private static func clusterMap() -> [Int: String] {
        var result: [Int: String] = [:]
        let root = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard root != 0 else { return result }
        defer { IOObjectRelease(root) }

        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(root, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return result }
        defer { IOObjectRelease(iterator) }

        var child = IOIteratorNext(iterator)
        while child != 0 {
            defer { IOObjectRelease(child); child = IOIteratorNext(iterator) }
            func property(_ name: String) -> Any? {
                IORegistryEntryCreateCFProperty(child, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            var letter: String?
            if let data = property("cluster-type") as? Data {
                letter = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
            }
            var logicalID: Int?
            if let number = property("logical-cpu-id") as? NSNumber { logicalID = number.intValue }
            else if let data = property("logical-cpu-id") as? Data {
                logicalID = data.reversed().reduce(0) { ($0 << 8) | Int($1) }
            }
            if let letter, let logicalID, !letter.isEmpty { result[logicalID] = letter }
        }
        return result
    }

    private static func registryInt(_ property: String) -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            if let value = IORegistryEntrySearchCFProperty(
                service, kIOServicePlane, property as CFString, kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
            ) as? NSNumber {
                return value.intValue
            }
        }
        return nil
    }

    private static func aneIsPresent() -> Bool {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/arm-io/ane")
        if entry != 0 { IOObjectRelease(entry); return true }
        // Node naming varies by SoC; fall back to a service match.
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iterator) == kIOReturnSuccess else { return false }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            if let role = IORegistryEntryCreateCFProperty(service, "role" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Data,
               String(decoding: role.prefix { $0 != 0 }, as: UTF8.self) == "ANE" {
                return true
            }
        }
        return false
    }
}
