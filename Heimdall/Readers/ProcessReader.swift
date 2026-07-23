import Foundation
import IOKit

class ProcessReader {
    private var pidBuffer = [Int32](repeating: 0, count: 2048)
    private var nameBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))

    func readTickSnapshot(includeNetwork: Bool = true) -> ProcessTickSnapshot {
        let timestamp = Date()
        return ProcessTickSnapshot(
            timestamp: timestamp,
            processes: readAllProcessMetrics(),
            networkByName: includeNetwork ? readNetworkMetrics() : [:],
            gpuByPID: readGPUMetrics()
        )
    }

    private func readAllProcessMetrics() -> [Int32: ProcessTickMetrics] {
        let bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pidBuffer, Int32(MemoryLayout<Int32>.stride * pidBuffer.count))
        guard bufferSize > 0 else { return [:] }
        let count = Int(bufferSize) / MemoryLayout<Int32>.stride

        var processes: [Int32: ProcessTickMetrics] = [:]
        processes.reserveCapacity(min(count, 256))

        for i in 0..<count {
            let pid = pidBuffer[i]
            guard pid > 0 else { continue }

            var taskInfo = proc_taskinfo()
            let size = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, Int32(MemoryLayout<proc_taskinfo>.size))
            guard size == MemoryLayout<proc_taskinfo>.size else { continue }

            nameBuffer[0] = 0
            proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            let name = String(cString: nameBuffer)
            guard !name.isEmpty else { continue }

            processes[pid] = ProcessTickMetrics(
                name: name,
                cpuTimeNs: taskInfo.pti_total_user + taskInfo.pti_total_system,
                residentBytes: taskInfo.pti_resident_size,
                pageIns: UInt64(max(taskInfo.pti_pageins, 0))
            )
        }

        return processes
    }

    private func readNetworkMetrics() -> [String: UInt64] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-L", "1", "-J", "bytes_in,bytes_out"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return [:]
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [:] }

        var metrics: [String: UInt64] = [:]
        let lines = output.components(separatedBy: "\n")

        for line in lines.dropFirst() {
            let parts = line.split(separator: ",")
            guard parts.count >= 3 else { continue }

            var name = String(parts[0]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name != "process" else { continue }

            if let dotRange = name.range(of: "."), Int(name[dotRange.upperBound...]) != nil {
                name = String(name[..<dotRange.lowerBound])
            }

            let bytesIn = UInt64(Double(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0)
            let bytesOut = UInt64(Double(parts[2].trimmingCharacters(in: .whitespaces)) ?? 0)
            let total = bytesIn + bytesOut
            guard total > 0 else { continue }

            metrics[name, default: 0] += total
        }

        return metrics
    }

    private func readGPUMetrics() -> [Int32: ProcessGPUMetrics] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"), &iterator) == kIOReturnSuccess else {
            return [:]
        }
        defer { IOObjectRelease(iterator) }

        var metrics: [Int32: ProcessGPUMetrics] = [:]

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
                      let (pid, name) = parseGPUClientCreator(creator) else {
                    continue
                }

                let gpuTimeNs = sumAccumulatedGPUTime(from: child)
                guard gpuTimeNs > 0 else { continue }

                if let existing = metrics[pid] {
                    metrics[pid] = ProcessGPUMetrics(name: name, gpuTimeNs: existing.gpuTimeNs + gpuTimeNs)
                } else {
                    metrics[pid] = ProcessGPUMetrics(name: name, gpuTimeNs: gpuTimeNs)
                }
            }
        }

        return metrics
    }

    private func parseGPUClientCreator(_ creator: String) -> (pid: Int32, name: String)? {
        guard creator.hasPrefix("pid ") else { return nil }
        let remainder = creator.dropFirst(4)
        guard let commaIndex = remainder.firstIndex(of: ",") else { return nil }
        let pidString = remainder[..<commaIndex].trimmingCharacters(in: .whitespaces)
        guard let pid = Int32(pidString) else { return nil }
        let name = remainder[remainder.index(after: commaIndex)...].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return (pid, name)
    }

    private func sumAccumulatedGPUTime(from entry: io_registry_entry_t) -> UInt64 {
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

enum ProcessTerminator {
    static func isRunning(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0
    }

    static func terminate(pid: Int32) {
        guard pid > 1, pid != ProcessInfo.processInfo.processIdentifier else { return }
        kill(pid, SIGTERM)
    }
}
