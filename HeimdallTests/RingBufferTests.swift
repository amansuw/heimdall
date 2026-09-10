import Foundation
import Testing

@Suite("Ring buffer")
struct RingBufferTests {

    struct Sample: TimestampedSample, Equatable {
        let timestamp: Date
        let value: Int
    }

    @Test func keepsTheNewestElementsInOrderAfterWrapping() {
        var buffer = RingBuffer<Int>(capacity: 4)
        for i in 1...10 { buffer.append(i) }
        #expect(buffer.count == 4)
        #expect(buffer.toArray() == [7, 8, 9, 10])
        #expect(buffer.first == 7)
        #expect(buffer.last == 10)
    }

    @Test func anEmptyBufferHasNothing() {
        let buffer = RingBuffer<Sample>(capacity: 8)
        #expect(buffer.toArray().isEmpty)
        #expect(buffer.first == nil)
        #expect(buffer.last == nil)
        #expect(buffer.elements(since: .distantPast).isEmpty)
    }

    /// Charts and process rankings window history with a binary search. It must
    /// agree with the obvious linear filter for any capacity, fill level, irregular
    /// cadence (including repeated timestamps) and cutoff.
    @Test(arguments: 0..<150)
    func windowingMatchesALinearFilter(seed: Int) {
        var rng = SeededGenerator(seed: UInt64(seed))
        let capacity = Int.random(in: 1...64, using: &rng)
        var buffer = RingBuffer<Sample>(capacity: capacity)
        var appended: [Sample] = []
        var time = Date(timeIntervalSinceReferenceDate: 0)

        for i in 0..<Int.random(in: 0...200, using: &rng) {
            time = time.addingTimeInterval(Double(Int.random(in: 0...5, using: &rng)))
            let sample = Sample(timestamp: time, value: i)
            buffer.append(sample)
            appended.append(sample)
        }

        let retained = Array(appended.suffix(capacity))
        #expect(buffer.toArray() == retained)

        let span = time.timeIntervalSinceReferenceDate
        for _ in 0..<20 {
            let cutoff = Date(timeIntervalSinceReferenceDate: Double.random(in: -5...(span + 5), using: &rng))
            let expected = retained.filter { $0.timestamp >= cutoff }
            #expect(buffer.elements(since: cutoff) == expected)

            var visited: [Sample] = []
            buffer.forEachElement(since: cutoff) { visited.append($0) }
            #expect(visited == expected)
        }
    }
}
