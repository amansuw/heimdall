import Foundation

/// Fixed-size circular buffer. O(1) append, zero allocations after init.
/// Used for all history arrays to avoid heap churn.
struct RingBuffer<Element> {
    private var storage: [Element?]
    private var writeIndex: Int = 0
    private(set) var count: Int = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.storage = [Element?](repeating: nil, count: capacity)
    }

    mutating func append(_ element: Element) {
        storage[writeIndex] = element
        writeIndex = (writeIndex + 1) % capacity
        if count < capacity { count += 1 }
    }

    /// Returns elements in chronological order (oldest first).
    func toArray() -> [Element] {
        guard count > 0 else { return [] }
        var result = [Element]()
        result.reserveCapacity(count)
        let start = count < capacity ? 0 : writeIndex
        for i in 0..<count {
            let idx = (start + i) % capacity
            if let el = storage[idx] {
                result.append(el)
            }
        }
        return result
    }

    /// Returns the most recent element.
    var last: Element? {
        guard count > 0 else { return nil }
        let idx = (writeIndex - 1 + capacity) % capacity
        return storage[idx]
    }

    /// Returns the oldest element.
    var first: Element? {
        guard count > 0 else { return nil }
        if count < capacity { return storage[0] }
        return storage[writeIndex]
    }

    /// Returns elements within a time window (requires Element to have a timestamp).
    /// For generic use, caller should filter the array.
    mutating func clear() {
        storage = [Element?](repeating: nil, count: capacity)
        writeIndex = 0
        count = 0
    }

    var isEmpty: Bool { count == 0 }
    var isFull: Bool { count == capacity }

    subscript(index: Int) -> Element? {
        guard index >= 0 && index < count else { return nil }
        let start = count < capacity ? 0 : writeIndex
        let idx = (start + index) % capacity
        return storage[idx]
    }
}
