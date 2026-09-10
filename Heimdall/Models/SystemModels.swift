import Foundation
import IOKit
import IOKit.ps

// MARK: - Top Process

struct TopProcess: Identifiable, Sendable {
    let pid: Int32
    let name: String
    let value: Double
    let formattedValue: String

    var id: String { pid > 0 ? "\(pid)" : "net-\(name)" }

    var canTerminate: Bool {
        pid > 1 && pid != ProcessInfo.processInfo.processIdentifier
    }
}

// MARK: - CPU

/// One CPU cluster as the hardware reports it — Performance, Efficiency, or
/// whatever a future SoC introduces. Heimdall never assumes there are exactly two,
/// nor that a cluster owns a particular range of core indices.
struct CPUCluster: Identifiable, Sendable {
    let id: Int
    let name: String
    /// Raw cluster-type from the device tree ("P", "E", ...). Empty on Intel.
    let letter: String
    let coreIndices: [Int]
    var usage: Double = 0
}

struct CPUUsage: Sendable {
    var system: Double = 0
    var user: Double = 0
    var idle: Double = 0
    var total: Double = 0

    /// Fastest first. Empty until the first sample lands.
    var clusters: [CPUCluster] = []

    struct CoreUsage: Identifiable, Sendable {
        let id: Int
        let usage: Double
        let clusterID: Int
    }
    var perCore: [CoreUsage] = []
}

struct CPUFrequency: Sendable {
    var allCores: Int = 0
    /// Keyed by CPUCluster.id. Empty when the chip is not in the estimate table.
    var perCluster: [Int: Int] = [:]

    /// Derived from load against a per-chip ceiling, not measured. Apple Silicon
    /// exposes no usable frequency sysctl, so the UI must say so.
    var isEstimated: Bool { !perCluster.isEmpty }
}

struct LoadAverage: Sendable {
    var oneMinute: Double = 0
    var fiveMinute: Double = 0
    var fifteenMinute: Double = 0
}

// MARK: - GPU

struct GPUUsage: Sendable {
    var modelName: String = "Unknown"
    /// Number of GPU cores reported by the IORegistry (0 when unknown).
    var coreCount: Int = 0
    var utilization: Double = 0
    var renderUtilization: Double = 0
    var tilerUtilization: Double = 0
}

// MARK: - Memory

struct MemoryBreakdown: Sendable {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var free: UInt64 = 0
    var swap: UInt64 = 0
    var pressureLevel: Int = 0

    var usagePercent: Double {
        guard total > 0 else { return 0 }
        return Double(used) / Double(total) * 100
    }
}

// MARK: - Disk

struct DiskInfo: Identifiable, Sendable {
    let id: String
    let name: String
    let totalBytes: UInt64
    let freeBytes: UInt64

    var usedBytes: UInt64 { totalBytes - freeBytes }
    var usagePercent: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes) * 100
    }
}

struct DiskIO: Sendable {
    var readBytesPerSec: UInt64 = 0
    var writeBytesPerSec: UInt64 = 0
}

// MARK: - Network

struct NetworkInterface: Identifiable, Sendable {
    let id: String
    var displayName: String = ""
    var macAddress: String = ""
    var speed: String = ""
    var localIP: String = ""
    var ipv6: String = ""
    var isUp: Bool = false
}

struct NetworkStats: Sendable {
    var downloadBytesPerSec: UInt64 = 0
    var uploadBytesPerSec: UInt64 = 0
    var totalDownload: UInt64 = 0
    var totalUpload: UInt64 = 0
    var latencyMs: Double = 0
    var jitterMs: Double = 0
    var publicIP: String = ""
    var publicIPv6: String = ""
    var dnsServers: [String] = []
    var activeInterface: NetworkInterface?
}

// MARK: - Battery

struct BatteryInfo: Sendable {
    var level: Double = 0
    var isCharging: Bool = false
    var isPluggedIn: Bool = false
    var source: String = "Battery"
    var timeRemaining: Int = -1
    var healthPercent: Double = 0
    var designCapacity: Int = 0
    var maxCapacity: Int = 0
    var currentCapacity: Int = 0
    var cycleCount: Int = 0
    var power: Double = 0
    var temperature: Double = 0
    var voltage: Double = 0
    var adapterWatts: Int = 0
    var adapterCurrent: Int = 0
    var adapterVoltage: Int = 0
    var hasBattery: Bool = false
}

// MARK: - Fan

struct FanInfo: Identifiable, Sendable {
    let id: Int
    let index: Int
    var currentSpeed: Double
    var minSpeed: Double
    var maxSpeed: Double
    var targetSpeed: Double
    var isManual: Bool
    var selectedSpeedLabel: String = "Auto"

    var speedPercentage: Double {
        guard maxSpeed > minSpeed else { return 0 }
        return max(0, ((currentSpeed - minSpeed) / (maxSpeed - minSpeed)) * 100.0)
    }

    var isIdle: Bool { currentSpeed <= minSpeed }

    /// "Left"/"Right" only describes a two-fan notebook. A Mac mini or Studio has
    /// differently placed fans and a Mac Pro has more of them, so anywhere else
    /// this falls back to numbering rather than asserting a layout.
    var name: String {
        guard FanNaming.usesLeftRight, index < 2 else { return "Fan \(index + 1)" }
        return index == 0 ? "Left Fan" : "Right Fan"
    }
}

enum FanNaming {
    /// Only notebooks have a left and a right fan.
    ///
    /// Detected by the presence of an internal battery rather than by model
    /// string: on Apple Silicon hw.model reads "Mac15,6", not "MacBookPro18,3",
    /// so a name-prefix test silently fails on exactly the machines it is meant
    /// to match. Cached — the chassis does not change while the process runs.
    static let usesLeftRight: Bool = {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AppleSmartBattery"),
                                           &iterator) == kIOReturnSuccess else { return false }
        defer { IOObjectRelease(iterator) }
        let service = IOIteratorNext(iterator)
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }()
}

// MARK: - History Snapshots

/// Anything a chart can plot or a ring buffer can window: it carries the
/// wall-clock time of the sample. Charts plot against these timestamps, never
/// against array index — the polling cadence is not constant (1s fan-boost /
/// 2s visible / 30s background).
protocol TimestampedSample {
    var timestamp: Date { get }
}

extension RingBuffer where Element: TimestampedSample {
    /// Logical index of the oldest element whose timestamp is >= `cutoff`.
    /// O(log n), no allocation. Assumes chronological append order.
    func firstIndex(atOrAfter cutoff: Date) -> Int {
        var low = 0
        var high = count
        while low < high {
            let mid = low + (high - low) / 2
            if let element = self[mid], element.timestamp >= cutoff {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low
    }

    /// Elements newer than `cutoff`, in chronological order.
    /// O(log n + k) where k is the number actually returned — elements outside
    /// the window are never copied.
    func elements(since cutoff: Date) -> [Element] {
        guard count > 0 else { return [] }
        let start = firstIndex(atOrAfter: cutoff)
        guard start < count else { return [] }
        var result = [Element]()
        result.reserveCapacity(count - start)
        for index in start..<count {
            if let element = self[index] { result.append(element) }
        }
        return result
    }

    /// Iterates elements newer than `cutoff` without allocating an array.
    func forEachElement(since cutoff: Date, _ body: (Element) -> Void) {
        guard count > 0 else { return }
        let start = firstIndex(atOrAfter: cutoff)
        guard start < count else { return }
        for index in start..<count {
            if let element = self[index] { body(element) }
        }
    }
}

struct CPUSnapshot: Sendable, TimestampedSample {
    let timestamp: Date
    let total: Double
    let user: Double
    let system: Double
}

/// `nil` means the tick found no matching sensors — a MISSING sample, not 0.
/// Charts break the line across these instead of plotting a false dip to zero.
struct TemperatureSnapshot: Sendable, TimestampedSample {
    let timestamp: Date
    let avgCPU: Double?
    let avgGPU: Double?
    let maxCPU: Double?
    let maxGPU: Double?
}

struct NetworkSnapshot: Sendable, TimestampedSample {
    let timestamp: Date
    let downloadBytesPerSec: UInt64
    let uploadBytesPerSec: UInt64
}

struct DiskIOSnapshot: Sendable, TimestampedSample {
    let timestamp: Date
    let readBytesPerSec: UInt64
    let writeBytesPerSec: UInt64
}

struct GPUSnapshot: Sendable, TimestampedSample {
    let timestamp: Date
    let utilization: Double
    let renderUtilization: Double
    let tilerUtilization: Double
}

struct RAMSnapshot: Sendable, TimestampedSample {
    let timestamp: Date
    let usagePercent: Double
    let appBytes: UInt64
    let wiredBytes: UInt64
    let compressedBytes: UInt64
}
