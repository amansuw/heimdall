import Foundation

struct ProcessTickMetrics: Sendable {
    let name: String
    let cpuTimeNs: UInt64
    let residentBytes: UInt64
    let pageIns: UInt64
}

struct ProcessGPUMetrics: Sendable {
    let name: String
    let gpuTimeNs: UInt64
}

struct ProcessTickSnapshot: Sendable, TimestampedSample {
    let timestamp: Date
    let processes: [Int32: ProcessTickMetrics]
    let networkByName: [String: UInt64]
    let gpuByPID: [Int32: ProcessGPUMetrics]
}

@Observable
final class ProcessHistory {
    private(set) var revision = 0
    @ObservationIgnored private var ticks = RingBuffer<ProcessTickSnapshot>(capacity: 90)
    @ObservationIgnored private var terminatedPIDs = Set<Int32>()
    @ObservationIgnored private var terminatedNames = Set<String>()

    /// One ranking result, tagged with the data revision and window it was
    /// computed from. The `topX` accessors run from SwiftUI `body`, which
    /// re-evaluates on *any* observed change; without this, every render
    /// re-walked up to 90 ticks of ~500 processes per metric. The cache is
    /// `@ObservationIgnored` so filling it cannot itself trigger observation.
    private struct RankingCache {
        let revision: Int
        let window: TimeInterval
        let limit: Int
        let coreCount: Int
        let value: [TopProcess]

        func matches(revision: Int, window: TimeInterval, limit: Int, coreCount: Int) -> Bool {
            self.revision == revision && self.window == window && self.limit == limit && self.coreCount == coreCount
        }
    }

    @ObservationIgnored private var cpuCache: RankingCache?
    @ObservationIgnored private var gpuCache: RankingCache?
    @ObservationIgnored private var ramCache: RankingCache?
    @ObservationIgnored private var diskCache: RankingCache?
    @ObservationIgnored private var networkCache: RankingCache?

    func append(_ snapshot: ProcessTickSnapshot) {
        ticks.append(snapshot)
        // Bound terminated-process bookkeeping so it can't grow forever.
        if terminatedPIDs.count > 400 { terminatedPIDs.removeAll(keepingCapacity: true) }
        if terminatedNames.count > 400 { terminatedNames.removeAll(keepingCapacity: true) }
        revision += 1
    }

    func markTerminated(pid: Int32, name: String) {
        if pid > 0 { terminatedPIDs.insert(pid) }
        terminatedNames.insert(name)
        revision += 1
    }

    private func isListed(pid: Int32, name: String) -> Bool {
        if terminatedNames.contains(name) { return false }
        guard pid > 0 else { return true }
        if terminatedPIDs.contains(pid) { return false }
        return ProcessTerminator.isRunning(pid: pid)
    }

    func topCPU(window: TimeInterval, limit: Int, coreCount: Int) -> [TopProcess] {
        if let cpuCache, cpuCache.matches(revision: revision, window: window, limit: limit, coreCount: coreCount) {
            return cpuCache.value
        }
        let result = rankByDelta(
            window: window,
            limit: limit,
            value: { last, first, elapsed in
                let deltaNs = last.cpuTimeNs > first.cpuTimeNs ? last.cpuTimeNs - first.cpuTimeNs : 0
                guard deltaNs > 0, elapsed > 0 else { return 0 }
                return Double(deltaNs) / 1_000_000_000.0 / elapsed / Double(max(coreCount, 1)) * 100.0
            },
            format: { Self.formatPercent($0) }
        )
        cpuCache = RankingCache(revision: revision, window: window, limit: limit, coreCount: coreCount, value: result)
        return result
    }

    func topGPU(window: TimeInterval, limit: Int) -> [TopProcess] {
        if let gpuCache, gpuCache.matches(revision: revision, window: window, limit: limit, coreCount: 0) {
            return gpuCache.value
        }
        let result = rankGPUByDelta(
            window: window,
            limit: limit,
            value: { last, first, elapsed in
                let deltaNs = last.gpuTimeNs > first.gpuTimeNs ? last.gpuTimeNs - first.gpuTimeNs : 0
                guard deltaNs > 0, elapsed > 0 else { return 0 }
                return Double(deltaNs) / 1_000_000_000.0 / elapsed * 100.0
            },
            format: { Self.formatPercent($0) }
        )
        gpuCache = RankingCache(revision: revision, window: window, limit: limit, coreCount: 0, value: result)
        return result
    }

    private static func formatPercent(_ value: Double) -> String {
        if value > 0 && value < 0.1 { return "<0.1%" }
        return String(format: "%.1f%%", value)
    }

    func topRAM(window: TimeInterval, limit: Int) -> [TopProcess] {
        if let ramCache, ramCache.matches(revision: revision, window: window, limit: limit, coreCount: 0) {
            return ramCache.value
        }
        let result = computeTopRAM(window: window, limit: limit)
        ramCache = RankingCache(revision: revision, window: window, limit: limit, coreCount: 0, value: result)
        return result
    }

    private func computeTopRAM(window: TimeInterval, limit: Int) -> [TopProcess] {
        let windowTicks = ticks(in: window)
        guard !windowTicks.isEmpty else { return [] }

        var totals: [Int32: (name: String, bytes: UInt64, count: Int)] = [:]
        for tick in windowTicks {
            for (pid, metrics) in tick.processes {
                var entry = totals[pid] ?? (metrics.name, 0, 0)
                entry.bytes += metrics.residentBytes
                entry.count += 1
                totals[pid] = entry
            }
        }

        return totals
            .map { pid, entry in
                let average = Double(entry.bytes) / Double(max(entry.count, 1))
                return (pid, entry.name, average)
            }
            .filter { isListed(pid: $0.0, name: $0.1) && $0.2 > 0 }
            .sorted { $0.2 > $1.2 }
            .prefix(limit)
            .map { pid, name, value in
                TopProcess(pid: pid, name: name, value: value, formattedValue: ByteFormatter.format(UInt64(value)))
            }
    }

    func topDiskIO(window: TimeInterval, limit: Int) -> [TopProcess] {
        if let diskCache, diskCache.matches(revision: revision, window: window, limit: limit, coreCount: 0) {
            return diskCache.value
        }
        let result = rankByDelta(
            window: window,
            limit: limit,
            value: { last, first, _ in
                let delta = last.pageIns > first.pageIns ? last.pageIns - first.pageIns : 0
                return Double(delta)
            },
            format: { value in
                let count = Int(value)
                if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
                if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
                return "\(count)"
            }
        )
        diskCache = RankingCache(revision: revision, window: window, limit: limit, coreCount: 0, value: result)
        return result
    }

    func topNetwork(window: TimeInterval, limit: Int) -> [TopProcess] {
        if let networkCache, networkCache.matches(revision: revision, window: window, limit: limit, coreCount: 0) {
            return networkCache.value
        }
        let result = computeTopNetwork(window: window, limit: limit)
        networkCache = RankingCache(revision: revision, window: window, limit: limit, coreCount: 0, value: result)
        return result
    }

    private func computeTopNetwork(window: TimeInterval, limit: Int) -> [TopProcess] {
        let windowTicks = ticks(in: window)
        guard !windowTicks.isEmpty else { return [] }

        var totals: [String: UInt64] = [:]
        for tick in windowTicks {
            for (name, bytes) in tick.networkByName {
                totals[name, default: 0] += bytes
            }
        }

        return totals
            .filter { isListed(pid: pid(forProcessNamed: $0.key, in: windowTicks), name: $0.key) && $0.value > 0 }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { entry in
                TopProcess(
                    pid: pid(forProcessNamed: entry.key, in: windowTicks),
                    name: entry.key,
                    value: Double(entry.value),
                    formattedValue: ByteFormatter.format(entry.value)
                )
            }
    }

    /// Ticks inside the window, sliced straight out of the ring buffer with a
    /// binary search — no full-buffer copy, no filter pass.
    private func ticks(in window: TimeInterval) -> [ProcessTickSnapshot] {
        ticks.elements(since: Date().addingTimeInterval(-window))
    }

    private func rankGPUByDelta(
        window: TimeInterval,
        limit: Int,
        value: (ProcessGPUMetrics, ProcessGPUMetrics, TimeInterval) -> Double,
        format: (Double) -> String
    ) -> [TopProcess] {
        let windowTicks = ticks(in: window)
        guard !windowTicks.isEmpty else { return [] }

        var firstByPID: [Int32: ProcessGPUMetrics] = [:]
        var lastByPID: [Int32: ProcessGPUMetrics] = [:]
        var firstTimestamp: Date?
        var lastTimestamp: Date?

        for tick in windowTicks {
            if firstTimestamp == nil { firstTimestamp = tick.timestamp }
            lastTimestamp = tick.timestamp
            for (pid, metrics) in tick.gpuByPID {
                if firstByPID[pid] == nil {
                    firstByPID[pid] = metrics
                }
                lastByPID[pid] = metrics
            }
        }

        let elapsed = lastTimestamp?.timeIntervalSince(firstTimestamp ?? lastTimestamp ?? Date()) ?? 0

        return lastByPID.compactMap { pid, last -> (Int32, String, Double)? in
            guard isListed(pid: pid, name: last.name) else { return nil }
            guard let first = firstByPID[pid] else { return nil }
            let metric = value(last, first, elapsed)
            guard metric > 0 else { return nil }
            return (pid, last.name, metric)
        }
        .sorted { $0.2 > $1.2 }
        .prefix(limit)
        .map { pid, name, metric in
            TopProcess(pid: pid, name: name, value: metric, formattedValue: format(metric))
        }
    }

    private func rankByDelta(
        window: TimeInterval,
        limit: Int,
        value: (ProcessTickMetrics, ProcessTickMetrics, TimeInterval) -> Double,
        format: (Double) -> String
    ) -> [TopProcess] {
        let windowTicks = ticks(in: window)
        guard !windowTicks.isEmpty else { return [] }

        var firstByPID: [Int32: ProcessTickMetrics] = [:]
        var lastByPID: [Int32: ProcessTickMetrics] = [:]
        var firstTimestamp: Date?
        var lastTimestamp: Date?

        for tick in windowTicks {
            if firstTimestamp == nil { firstTimestamp = tick.timestamp }
            lastTimestamp = tick.timestamp
            for (pid, metrics) in tick.processes {
                if firstByPID[pid] == nil {
                    firstByPID[pid] = metrics
                }
                lastByPID[pid] = metrics
            }
        }

        let elapsed = lastTimestamp?.timeIntervalSince(firstTimestamp ?? lastTimestamp ?? Date()) ?? 0

        return lastByPID.compactMap { pid, last -> (Int32, String, Double)? in
            guard isListed(pid: pid, name: last.name) else { return nil }
            guard let first = firstByPID[pid] else { return nil }
            let metric = value(last, first, elapsed)
            guard metric > 0 else { return nil }
            return (pid, last.name, metric)
        }
        .sorted { $0.2 > $1.2 }
        .prefix(limit)
        .map { pid, name, metric in
            TopProcess(pid: pid, name: name, value: metric, formattedValue: format(metric))
        }
    }

    private func pid(forProcessNamed name: String, in ticks: [ProcessTickSnapshot]) -> Int32 {
        for tick in ticks.reversed() {
            for (pid, metrics) in tick.processes where metrics.name == name {
                return pid
            }
        }
        return 0
    }
}
