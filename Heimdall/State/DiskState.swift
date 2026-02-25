import Foundation

@Observable
class DiskState {
    var disks: [DiskInfo] = []
    var io = DiskIO()
    var topProcesses: [TopProcess] = []
    var ioHistory = RingBuffer<DiskIOSnapshot>(capacity: 1800)

    func applySpace(_ result: DiskSpaceResult) {
        disks = result.disks
    }

    func applyIO(_ result: DiskIOResult) {
        io = result.io
        ioHistory.append(result.snapshot)
    }
}
