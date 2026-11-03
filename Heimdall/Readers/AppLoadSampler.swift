import AppKit
import Foundation
import IOKit

/// Live CPU / GPU load for a fan-curve application target.
///
/// Matches PIDs by bundle identifier (via `NSRunningApplication`) and/or process
/// name (CLI workers). Percentages are deltas between consecutive `sample`
/// calls — the first call seeds state and returns zeros.
final class AppLoadSampler: @unchecked Sendable {
    struct Sample: Sendable {
        var cpuPercent: Double = 0
        var gpuPercent: Double = 0
    }

    struct Target: Equatable, Sendable {
        var bundleIdentifier: String = ""
        var processName: String = ""

        var isEmpty: Bool {
            bundleIdentifier.isEmpty && processName.isEmpty
        }
    }

    private struct PIDSample {
        var cpuTimeNs: UInt64
        var gpuTimeNs: UInt64
    }

    private let lock = NSLock()
    private var previous: [Int32: PIDSample] = [:]
    private var previousAt: Date?
    private var lastSample = Sample()
    private var trackedTarget = Target()
    private var nameBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    private var pidBuffer = [Int32](repeating: 0, count: 2048)

    /// Latest published sample. Safe to read from any queue.
    var current: Sample {
        lock.withLock { lastSample }
    }

    /// Clears delta state so the next sample reseeds (e.g. after the target changes).
    func reset() {
        lock.withLock {
            previous = [:]
            previousAt = nil
            lastSample = Sample()
            trackedTarget = Target()
        }
    }

    /// Samples matching processes for `target` and returns CPU/GPU %.
    /// `coreCount` normalizes CPU the same way process rankings do.
    @discardableResult
    func sample(target: Target, coreCount: Int) -> Sample {
        guard !target.isEmpty else {
            reset()
            return Sample()
        }

        let pids = Self.resolvePIDs(
            bundleIdentifier: target.bundleIdentifier,
            processName: target.processName,
            pidBuffer: &pidBuffer,
            nameBuffer: &nameBuffer
        )

        let now = Date()
        var currentSamples: [Int32: PIDSample] = [:]
        currentSamples.reserveCapacity(pids.count)

        let gpuByPID = Self.readGPUTimeByPID()

        for pid in pids {
            var taskInfo = proc_taskinfo()
            let size = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, Int32(MemoryLayout<proc_taskinfo>.size))
            let cpuTime = size == MemoryLayout<proc_taskinfo>.size
                ? UInt64(taskInfo.pti_total_user) + UInt64(taskInfo.pti_total_system)
                : 0
            currentSamples[pid] = PIDSample(
                cpuTimeNs: cpuTime,
                gpuTimeNs: gpuByPID[pid] ?? 0
            )
        }

        return lock.withLock {
            if trackedTarget != target {
                trackedTarget = target
                previous = currentSamples
                previousAt = now
                lastSample = Sample()
                return lastSample
            }

            defer {
                previous = currentSamples
                previousAt = now
            }

            guard let previousAt, !previous.isEmpty else {
                lastSample = Sample()
                return lastSample
            }

            let elapsed = now.timeIntervalSince(previousAt)
            guard elapsed > 0 else {
                return lastSample
            }

            var cpuDelta: UInt64 = 0
            var gpuDelta: UInt64 = 0
            for (pid, sample) in currentSamples {
                guard let prior = previous[pid] else { continue }
                if sample.cpuTimeNs > prior.cpuTimeNs {
                    cpuDelta += sample.cpuTimeNs - prior.cpuTimeNs
                }
                if sample.gpuTimeNs > prior.gpuTimeNs {
                    gpuDelta += sample.gpuTimeNs - prior.gpuTimeNs
                }
            }

            let cores = Double(max(coreCount, 1))
            let cpuPercent = min(100, Double(cpuDelta) / 1_000_000_000.0 / elapsed / cores * 100.0)
            let gpuPercent = min(100, Double(gpuDelta) / 1_000_000_000.0 / elapsed * 100.0)
            lastSample = Sample(cpuPercent: cpuPercent, gpuPercent: gpuPercent)
            return lastSample
        }
    }

    // MARK: - PID resolution

    static func resolvePIDs(
        bundleIdentifier: String,
        processName: String,
        pidBuffer: inout [Int32],
        nameBuffer: inout [CChar]
    ) -> Set<Int32> {
        var pids = Set<Int32>()

        if !bundleIdentifier.isEmpty {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            for app in apps where app.processIdentifier > 0 {
                pids.insert(app.processIdentifier)
            }
        }

        if !processName.isEmpty {
            let count = listPIDs(into: &pidBuffer)
            for i in 0..<count {
                let pid = pidBuffer[i]
                guard pid > 0 else { continue }
                nameBuffer[0] = 0
                proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
                let name = String(cString: nameBuffer)
                if name == processName {
                    pids.insert(pid)
                }
            }
        }

        return pids
    }

    private static func listPIDs(into pidBuffer: inout [Int32]) -> Int {
        let bufferSize = proc_listpids(
            UInt32(PROC_ALL_PIDS), 0, &pidBuffer,
            Int32(MemoryLayout<Int32>.stride * pidBuffer.count)
        )
        guard bufferSize > 0 else { return 0 }
        return min(Int(bufferSize) / MemoryLayout<Int32>.stride, pidBuffer.count)
    }

    // MARK: - GPU time (same IORegistry path as ProcessReader)

    private static func readGPUTimeByPID() -> [Int32: UInt64] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"), &iterator) == kIOReturnSuccess else {
            return [:]
        }
        defer { IOObjectRelease(iterator) }

        var metrics: [Int32: UInt64] = [:]
        var accelerator = IOIteratorNext(iterator)
        while accelerator != 0 {
            defer { IOObjectRelease(accelerator); accelerator = IOIteratorNext(iterator) }

            var childIterator: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &childIterator) == kIOReturnSuccess else {
                continue
            }
            defer { IOObjectRelease(childIterator) }

            var child = IOIteratorNext(childIterator)
            while child != 0 {
                defer { IOObjectRelease(child); child = IOIteratorNext(childIterator) }

                guard let creator = IORegistryEntryCreateCFProperty(
                    child, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0
                )?.takeRetainedValue() as? String,
                      let pid = parseGPUClientPID(creator) else {
                    continue
                }

                let gpuTimeNs = sumAccumulatedGPUTime(from: child)
                guard gpuTimeNs > 0 else { continue }
                metrics[pid, default: 0] += gpuTimeNs
            }
        }
        return metrics
    }

    private static func parseGPUClientPID(_ creator: String) -> Int32? {
        guard creator.hasPrefix("pid ") else { return nil }
        let remainder = creator.dropFirst(4)
        guard let commaIndex = remainder.firstIndex(of: ",") else { return nil }
        let pidString = remainder[..<commaIndex].trimmingCharacters(in: .whitespaces)
        return Int32(pidString)
    }

    private static func sumAccumulatedGPUTime(from entry: io_registry_entry_t) -> UInt64 {
        guard let appUsage = IORegistryEntryCreateCFProperty(
            entry, "AppUsage" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [[String: Any]] else {
            return 0
        }

        var total: UInt64 = 0
        for usage in appUsage {
            if let gpuTime = usage["accumulatedGPUTime"] as? UInt64 {
                total += gpuTime
            } else if let gpuTime = usage["accumulatedGPUTime"] as? Int {
                total += UInt64(max(gpuTime, 0))
            } else if let gpuTime = usage["accumulatedGPUTime"] as? Int64 {
                total += UInt64(max(gpuTime, 0))
            }
        }
        return total
    }
}
