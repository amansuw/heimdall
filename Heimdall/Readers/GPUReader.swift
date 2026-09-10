import Foundation
import IOKit

struct GPUReaderResult: Sendable {
    let usage: GPUUsage
}

class GPUReader {
    private var previousIn: UInt64 = 0
    private var previousOut: UInt64 = 0

    /// Model name and core count never change while the app runs, so they are
    /// read from the IORegistry once instead of on every 2 s poll.
    private var cachedModelName: String?
    private var cachedCoreCount: Int = 0

    private var needsStaticProperties: Bool { cachedModelName == nil || cachedCoreCount == 0 }

    func read() -> GPUReaderResult {
        var usage = GPUUsage()

        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOAccelerator")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else {
            usage.modelName = cachedModelName ?? usage.modelName
            usage.coreCount = cachedCoreCount
            return GPUReaderResult(usage: usage)
        }
        defer { IOObjectRelease(iterator) }

        var pendingModel: String?
        var pendingCoreCount: Int?

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }

            // Only the PerformanceStatistics sub-dictionary is needed per tick;
            // copying the entire property dictionary was the expensive part.
            if let perfProps = property(service, "PerformanceStatistics") as? [String: Any] {
                if let deviceUtil = perfProps["Device Utilization %"] as? Int {
                    usage.utilization = Double(deviceUtil)
                } else if let gpuActivity = perfProps["GPU Activity(%)"] as? Int {
                    usage.utilization = Double(gpuActivity)
                }

                if let renderUtil = perfProps["Renderer Utilization %"] as? Int {
                    usage.renderUtilization = Double(renderUtil)
                }
                if let tilerUtil = perfProps["Tiler Utilization %"] as? Int {
                    usage.tilerUtilization = Double(tilerUtil)
                }
            }

            if needsStaticProperties {
                if let model = modelName(of: service) { pendingModel = model }
                if let cores = property(service, "gpu-core-count") as? Int { pendingCoreCount = cores }
            }

            if usage.utilization > 0 { break }
        }

        if cachedModelName == nil, let pendingModel { cachedModelName = pendingModel }
        if cachedCoreCount == 0, let pendingCoreCount, pendingCoreCount > 0 { cachedCoreCount = pendingCoreCount }

        if let cachedModelName { usage.modelName = cachedModelName }
        usage.coreCount = cachedCoreCount

        return GPUReaderResult(usage: usage)
    }

    private func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private func modelName(of entry: io_registry_entry_t) -> String? {
        guard let raw = property(entry, "model") else { return nil }
        if let modelStr = raw as? String { return modelStr }
        if let modelData = raw as? Data {
            return String(data: modelData, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) ?? "GPU"
        }
        return nil
    }
}
