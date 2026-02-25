import Foundation

// MARK: - Top Process

struct TopProcess: Identifiable, Sendable {
    let id: Int32
    let name: String
    let value: Double
    let formattedValue: String
}

// MARK: - CPU

struct CPUUsage: Sendable {
    var system: Double = 0
    var user: Double = 0
    var idle: Double = 0
    var total: Double = 0
    var efficiencyCores: Double = 0
    var performanceCores: Double = 0

    struct CoreUsage: Identifiable, Sendable {
        let id: Int
        let usage: Double
        let isEfficiency: Bool
    }
    var perCore: [CoreUsage] = []
}

struct CPUFrequency: Sendable {
    var allCores: Int = 0
    var efficiencyCores: Int = 0
    var performanceCores: Int = 0
}

struct LoadAverage: Sendable {
    var oneMinute: Double = 0
    var fiveMinute: Double = 0
    var fifteenMinute: Double = 0
}

// MARK: - GPU

struct GPUUsage: Sendable {
    var modelName: String = "Unknown"
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

    var name: String {
        switch index {
        case 0: return "Left Fan"
        case 1: return "Right Fan"
        default: return "Fan \(index + 1)"
        }
    }
}

// MARK: - History Snapshots

struct CPUSnapshot: Sendable {
    let timestamp: Date
    let total: Double
    let user: Double
    let system: Double
}

struct TemperatureSnapshot: Sendable {
    let timestamp: Date
    let avgCPU: Double
    let avgGPU: Double
    let maxCPU: Double
    let maxGPU: Double
}

struct NetworkSnapshot: Sendable {
    let timestamp: Date
    let downloadBytesPerSec: UInt64
    let uploadBytesPerSec: UInt64
}

struct DiskIOSnapshot: Sendable {
    let timestamp: Date
    let readBytesPerSec: UInt64
    let writeBytesPerSec: UInt64
}
