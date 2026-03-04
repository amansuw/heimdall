import Foundation

enum ByteFormatter {
    static func format(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        let kb = Double(bytes) / 1024
        return String(format: "%.0f KB", kb)
    }

    static func formatSpeed(_ bytesPerSec: UInt64) -> String {
        formatSpeed(Double(bytesPerSec))
    }

    static func formatSpeed(_ bytesPerSec: Double) -> String {
        let value = max(bytesPerSec, 0)
        let gb = value / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB/s", gb) }
        let mb = value / 1_048_576
        if mb >= 1 { return String(format: "%.1f MB/s", mb) }
        let kb = value / 1024
        if kb >= 1 { return String(format: "%.1f KB/s", kb) }
        return String(format: "%.0f B/s", value)
    }
}

enum TempFormatter {
    static func format(_ celsius: Double) -> String {
        String(format: "%.1f°C", celsius)
    }

    static func formatShort(_ celsius: Double) -> String {
        String(format: "%.0f°", celsius)
    }
}

enum UptimeFormatter {
    static func format(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
