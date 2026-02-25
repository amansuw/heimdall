import Foundation
import IOKit

struct DiskSpaceResult: Sendable {
    let disks: [DiskInfo]
}

struct DiskIOResult: Sendable {
    let io: DiskIO
    let snapshot: DiskIOSnapshot
}

class DiskReader {
    private var prevReadBytes: UInt64 = 0
    private var prevWriteBytes: UInt64 = 0
    private var prevTimestamp: Date?

    func readSpace() -> DiskSpaceResult {
        var disks: [DiskInfo] = []
        let fileManager = FileManager.default
        guard let mountedVolumes = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey
        ], options: [.skipHiddenVolumes]) else {
            return DiskSpaceResult(disks: [])
        }

        for url in mountedVolumes {
            guard let resources = try? url.resourceValues(forKeys: [
                .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey
            ]) else { continue }

            let name = resources.volumeName ?? url.lastPathComponent
            let total = UInt64(resources.volumeTotalCapacity ?? 0)
            let free = UInt64(resources.volumeAvailableCapacity ?? 0)

            if total > 0 {
                disks.append(DiskInfo(id: url.path, name: name, totalBytes: total, freeBytes: free))
            }
        }
        return DiskSpaceResult(disks: disks)
    }

    func readIO() -> DiskIOResult {
        var totalRead: UInt64 = 0
        var totalWrite: UInt64 = 0

        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOBlockStorageDriver")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else {
            let now = Date()
            return DiskIOResult(io: DiskIO(), snapshot: DiskIOSnapshot(timestamp: now, readBytesPerSec: 0, writeBytesPerSec: 0))
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }

            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let stats = dict["Statistics"] as? [String: Any] else { continue }

            if let bytesRead = stats["Bytes (Read)"] as? UInt64 {
                totalRead += bytesRead
            }
            if let bytesWritten = stats["Bytes (Write)"] as? UInt64 {
                totalWrite += bytesWritten
            }
        }

        let now = Date()
        var io = DiskIO()

        if let prevTime = prevTimestamp {
            let elapsed = now.timeIntervalSince(prevTime)
            if elapsed > 0 && totalRead >= prevReadBytes && totalWrite >= prevWriteBytes {
                io.readBytesPerSec = UInt64(Double(totalRead - prevReadBytes) / elapsed)
                io.writeBytesPerSec = UInt64(Double(totalWrite - prevWriteBytes) / elapsed)
            }
        }

        prevReadBytes = totalRead
        prevWriteBytes = totalWrite
        prevTimestamp = now

        return DiskIOResult(io: io, snapshot: DiskIOSnapshot(timestamp: now, readBytesPerSec: io.readBytesPerSec, writeBytesPerSec: io.writeBytesPerSec))
    }
}
