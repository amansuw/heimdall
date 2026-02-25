import Foundation

@Observable
class RAMState {
    var memory = MemoryBreakdown()
    var topProcesses: [TopProcess] = []

    func apply(_ result: RAMReaderResult) {
        memory = result.memory
    }
}
