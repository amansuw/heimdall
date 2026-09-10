import Foundation
import SwiftUI

// MARK: - Metric Colors

/// The single source of truth for how a metric maps to a color.
/// Every gauge, bar, chart tint and progress view in the app goes through here
/// so the same number always reads as the same color.
enum MetricColor {
    /// Percentage ladder (0-100) used for CPU / GPU / RAM / disk utilization.
    static func usage(_ percent: Double) -> Color {
        if percent <= 20 { return .blue }
        if percent <= 40 { return .green }
        if percent <= 60 { return .yellow }
        if percent <= 80 { return .orange }
        return .red
    }

    /// Temperature ladder in degrees Celsius.
    /// Non-positive readings mean "no sensor value" and render gray.
    static func temperature(_ celsius: Double) -> Color {
        if celsius <= 0 || celsius < 35 { return .gray }
        if celsius < 56 { return .green }
        if celsius < 75 { return .yellow }
        if celsius < 90 { return .orange }
        return .red
    }
}

// MARK: - Volume Filtering

/// Classifies mounted volumes by their mount path.
///
/// `DiskInfo.id` is the volume's mount path, so the traits we need (local vs.
/// network, writable vs. read-only) can be recovered without changing the
/// reader. Results are cached because these traits are fixed for the lifetime
/// of a mount and the lookup is called from a view body.
@MainActor
enum VolumeFilter {
    private static var cache: [String: Bool] = [:]

    /// True when the volume mounted at `mountPath` is a local, writable volume,
    /// i.e. not a network share and not a read-only mount such as a Time
    /// Machine snapshot or a sealed system image.
    ///
    /// Note: the macOS root volume reports as writable here even though `/`
    /// itself is sealed, because Foundation resolves the firmlinked data
    /// volume — so the boot disk is correctly kept.
    static func isLocalWritable(mountPath: String) -> Bool {
        if let cached = cache[mountPath] { return cached }
        let keys: Set<URLResourceKey> = [.volumeIsLocalKey, .volumeIsReadOnlyKey]
        let values = try? URL(fileURLWithPath: mountPath).resourceValues(forKeys: keys)
        // Missing values mean we could not classify it; keep the volume rather
        // than hiding a disk the user can see in Finder.
        let isLocal = values?.volumeIsLocal ?? true
        let isReadOnly = values?.volumeIsReadOnly ?? false
        let result = isLocal && !isReadOnly
        cache[mountPath] = result
        return result
    }
}

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

/// Sensors always report Celsius; conversion happens here, at the point of
/// display, so a single preference switches every readout in the app.
enum TempFormatter {
    private static var unit: TemperatureUnit { AppSettings.shared.temperatureUnit }

    static func format(_ celsius: Double) -> String {
        String(format: "%.1f%@", unit.convert(celsius), unit.suffix)
    }

    static func formatShort(_ celsius: Double) -> String {
        String(format: "%.0f°", unit.convert(celsius))
    }

    /// Whole degrees with the unit, for sparse labels such as a curve editor's axis ends.
    static func formatWhole(_ celsius: Double) -> String {
        String(format: "%.0f%@", unit.convert(celsius), unit.suffix)
    }

    /// Chart axis and tooltip labels. The chart plots Celsius values, but because
    /// the conversion is linear and monotonic, labelling a Celsius position with
    /// its Fahrenheit value is still correct — 40 on the axis really is 104 °F.
    static func axisLabel(_ celsius: Double) -> String {
        String(format: "%.0f°", unit.convert(celsius))
    }

    static func tooltipLabel(_ celsius: Double) -> String {
        String(format: "%.1f%@", unit.convert(celsius), unit.suffix)
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
