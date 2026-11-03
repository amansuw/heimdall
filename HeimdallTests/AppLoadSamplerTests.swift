import Foundation
import Testing

@Suite("App load sampler")
struct AppLoadSamplerTests {

    @Test func anEmptyTargetYieldsZeroLoad() {
        let sampler = AppLoadSampler()
        let sample = sampler.sample(target: .init(), coreCount: 8)
        #expect(sample.cpuPercent == 0)
        #expect(sample.gpuPercent == 0)
    }

    @Test func theFirstSampleOfALiveTargetSeedsWithoutAPercent() {
        let sampler = AppLoadSampler()
        let target = AppLoadSampler.Target(
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.apple.finder",
            processName: ""
        )
        // Finder / the test host may or may not match; either way the first
        // call only seeds and must not invent a load reading.
        let first = sampler.sample(target: target, coreCount: ProcessInfo.processInfo.processorCount)
        #expect(first.cpuPercent == 0)
        #expect(first.gpuPercent == 0)
    }
}
