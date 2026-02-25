import Foundation

@Observable
class GPUState {
    var usage = GPUUsage()

    func apply(_ result: GPUReaderResult) {
        usage = result.usage
    }
}
