import Foundation

struct ProcessTickMetrics: Sendable {
    let name: String
    let cpuTimeNs: UInt64
    let residentBytes: UInt64
    let pageIns: UInt64
}

struct ProcessTickSnapshot: Sendable {
    let timestamp: Date
    let processes: [Int32: ProcessTickMetrics]
    let networkByName: [String: UInt64]
}

@Observable
final class ProcessHistory {
    private(set) var revision = 0
    private var ticks = RingBuffer<ProcessTickSnapshot>(capacity: 400)
    private var terminatedPIDs = Set<Int32>()
    private var terminatedNames = Set<String>()

    func append(_ snapshot: ProcessTickSnapshot) {
        ticks.append(snapshot)
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
        rankByDelta(
            window: window,
            limit: limit,
            value: { last, first, elapsed in
                let deltaNs = last.cpuTimeNs > first.cpuTimeNs ? last.cpuTimeNs - first.cpuTimeNs : 0
                guard deltaNs > 0, elapsed > 0 else { return 0 }
                return Double(deltaNs) / 1_000_000_000.0 / elapsed / Double(max(coreCount, 1)) * 100.0
            },
            format: { String(format: "%.1f%%", $0) }
        )
    }

    func topRAM(window: TimeInterval, limit: Int) -> [TopProcess] {
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
        rankByDelta(
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
    }

    func topNetwork(window: TimeInterval, limit: Int) -> [TopProcess] {
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

    private func ticks(in window: TimeInterval) -> [ProcessTickSnapshot] {
        let cutoff = Date().addingTimeInterval(-window)
        return ticks.toArray().filter { $0.timestamp >= cutoff }
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
