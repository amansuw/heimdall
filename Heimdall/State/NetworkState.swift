import Foundation

@Observable
class NetworkState {
    var stats = NetworkStats()
    var topProcesses: [TopProcess] = []
    var history = RingBuffer<NetworkSnapshot>(capacity: 1800)

    func apply(_ result: NetworkReaderResult) {
        stats.downloadBytesPerSec = result.dlSpeed
        stats.uploadBytesPerSec = result.ulSpeed
        stats.totalDownload = result.totalIn
        stats.totalUpload = result.totalOut
        stats.activeInterface = result.activeIface
        history.append(result.snapshot)
    }
}
