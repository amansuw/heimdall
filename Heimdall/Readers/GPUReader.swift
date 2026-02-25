import Foundation
import IOKit

struct GPUReaderResult: Sendable {
    let usage: GPUUsage
}

class GPUReader {
    private var previousIn: UInt64 = 0
    private var previousOut: UInt64 = 0

    func read() -> GPUReaderResult {
        var usage = GPUUsage()

        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOAccelerator")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else {
            return GPUReaderResult(usage: usage)
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }

            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                  let dict = props?.takeRetainedValue() as? [String: Any] else { continue }

            if let perfProps = dict["PerformanceStatistics"] as? [String: Any] {
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

            if let modelStr = dict["model"] as? String {
                usage.modelName = modelStr
            } else if let modelData = dict["model"] as? Data {
                usage.modelName = String(data: modelData, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) ?? "GPU"
            }

            if usage.utilization > 0 { break }
        }

        return GPUReaderResult(usage: usage)
    }
}
