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
        let gb = Double(bytesPerSec) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB/s", gb) }
        let mb = Double(bytesPerSec) / 1_048_576
        if mb >= 1 { return String(format: "%.1f MB/s", mb) }
        let kb = Double(bytesPerSec) / 1024
        return String(format: "%.1f KB/s", kb)
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
