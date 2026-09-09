import Foundation
import IOKit

struct CPUReaderResult: Sendable {
    let usage: CPUUsage
    let load: LoadAverage
    let uptime: TimeInterval
    let freq: CPUFrequency
    let snapshot: CPUSnapshot
}

class CPUReader {
    private(set) var totalCores: Int = 0

    /// Clusters in display order, fastest first. Empty coreIndices never occur.
    private(set) var clusters: [CPUCluster] = []

    /// core index -> position in `clusters`
    private var clusterIDByCore: [Int: Int] = [:]

    /// Estimated ceiling per cluster, keyed the same way. Absent when the chip is
    /// not in the lookup table, in which case no frequency is reported at all.
    private var maxFreqMHzByCluster: [Int: Int] = [:]

    private var previousCoreTicks: [(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)] = []
    private var previousTotalTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) = (0, 0, 0, 0)

    init() {
        detectTopology()
    }

    // MARK: - Topology

    private func detectTopology() {
        totalCores = ProcessInfo.processInfo.processorCount

        // Membership comes from the device tree. Deriving it from core index order
        // (e.g. "the first N are performance cores") is wrong: on an M3 Pro the
        // efficiency cores occupy the *low* indices, and the ordering is an
        // implementation detail Apple can change between chips.
        let letterByCore = Self.readClusterMap()

        if letterByCore.isEmpty {
            // Intel, or an unreadable device tree: present one undifferentiated cluster
            // rather than inventing a split we cannot substantiate.
            clusters = [CPUCluster(id: 0, name: "CPU", letter: "", coreIndices: Array(0..<totalCores))]
        } else {
            clusters = Self.buildClusters(letterByCore: letterByCore, levels: Self.readPerfLevels())
        }

        for cluster in clusters {
            for core in cluster.coreIndices { clusterIDByCore[core] = cluster.id }
        }

        maxFreqMHzByCluster = Self.estimatedMaxFrequencies(for: clusters)
    }

    /// logical-cpu-id -> cluster-type letter, straight from IODeviceTree:/cpus.
    private static func readClusterMap() -> [Int: String] {
        var result: [Int: String] = [:]

        let root = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard root != 0 else { return result }
        defer { IOObjectRelease(root) }

        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(root, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return result }
        defer { IOObjectRelease(iterator) }

        var child = IOIteratorNext(iterator)
        while child != 0 {
            defer { IOObjectRelease(child); child = IOIteratorNext(iterator) }

            func property(_ name: String) -> Any? {
                IORegistryEntryCreateCFProperty(child, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }

            // cluster-type is an ASCII letter in a Data, sometimes NUL terminated.
            var letter: String?
            if let data = property("cluster-type") as? Data {
                letter = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
            } else if let text = property("cluster-type") as? String {
                letter = text
            }

            // logical-cpu-id arrives as a number on some systems, raw bytes on others.
            var logicalID: Int?
            if let number = property("logical-cpu-id") as? NSNumber {
                logicalID = number.intValue
            } else if let data = property("logical-cpu-id") as? Data {
                logicalID = data.reversed().reduce(0) { ($0 << 8) | Int($1) }
            }

            if let letter, let logicalID, !letter.isEmpty {
                result[logicalID] = letter
            }
        }
        return result
    }

    /// Performance levels from sysctl, fastest first. Supplies human names; the
    /// count comes from hw.nperflevels so a third cluster type needs no code change.
    private static func readPerfLevels() -> [(name: String, coreCount: Int)] {
        var levelCount: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.nperflevels", &levelCount, &size, nil, 0) == 0, levelCount > 0 else { return [] }

        return (0..<Int(levelCount)).compactMap { index in
            var nameSize = 0
            let nameKey = "hw.perflevel\(index).name"
            guard sysctlbyname(nameKey, nil, &nameSize, nil, 0) == 0, nameSize > 0 else { return nil }
            var nameBuf = [CChar](repeating: 0, count: nameSize)
            guard sysctlbyname(nameKey, &nameBuf, &nameSize, nil, 0) == 0 else { return nil }

            var cores: Int32 = 0
            var coreSize = MemoryLayout<Int32>.size
            guard sysctlbyname("hw.perflevel\(index).logicalcpu", &cores, &coreSize, nil, 0) == 0 else { return nil }

            return (String(cString: nameBuf), Int(cores))
        }
    }

    /// Pairs device-tree clusters with sysctl performance levels by core count so
    /// they inherit the OS's own names and fastest-first ordering. Falls back to
    /// letter-derived names when the two views disagree.
    private static func buildClusters(
        letterByCore: [Int: String],
        levels: [(name: String, coreCount: Int)]
    ) -> [CPUCluster] {
        var coresByLetter: [String: [Int]] = [:]
        for (core, letter) in letterByCore { coresByLetter[letter, default: []].append(core) }
        let groups = coresByLetter.map { (letter: $0.key, cores: $0.value.sorted()) }

        var unmatched = Array(levels.enumerated())
        var ranked: [(rank: Int, name: String, group: (letter: String, cores: [Int]))] = []

        for group in groups {
            guard let slot = unmatched.firstIndex(where: { $0.element.coreCount == group.cores.count }) else {
                ranked.removeAll()
                break
            }
            let (levelIndex, level) = unmatched.remove(at: slot)
            ranked.append((levelIndex, level.name, group))
        }

        if ranked.count == groups.count, !ranked.isEmpty {
            return ranked.sorted { $0.rank < $1.rank }.enumerated().map { index, entry in
                CPUCluster(id: index, name: entry.name, letter: entry.group.letter, coreIndices: entry.group.cores)
            }
        }

        // Fallback: name and order from the cluster letter alone.
        func rank(_ letter: String) -> Int {
            switch letter {
            case "P": return 0
            case "E": return 1
            default: return 2
            }
        }
        return groups
            .sorted { (rank($0.letter), $0.letter) < (rank($1.letter), $1.letter) }
            .enumerated()
            .map { index, group in
                CPUCluster(id: index, name: Self.name(forLetter: group.letter), letter: group.letter, coreIndices: group.cores)
            }
    }

    private static func name(forLetter letter: String) -> String {
        switch letter {
        case "P": return "Performance"
        case "E": return "Efficiency"
        case "": return "CPU"
        default: return "Cluster \(letter)"
        }
    }

    // MARK: - Frequency ceilings (estimates)

    /// Apple Silicon does not publish a usable hw.cpufrequency_max, so these come
    /// from a per-chip table. An unrecognised chip yields no entries, and the UI
    /// then shows nothing rather than a fabricated 0 MHz.
    private static func estimatedMaxFrequencies(for clusters: [CPUCluster]) -> [Int: Int] {
        var maxFreq: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.cpufrequency_max", &maxFreq, &size, nil, 0) == 0, maxFreq > 0 {
            let mhz = Int(maxFreq / 1_000_000)
            return Dictionary(uniqueKeysWithValues: clusters.map { ($0.id, mhz) })
        }

        var brandBuf = [CChar](repeating: 0, count: 256)
        var brandSize = brandBuf.count
        sysctlbyname("machdep.cpu.brand_string", &brandBuf, &brandSize, nil, 0)
        let brand = String(cString: brandBuf).lowercased()

        let pAndE: (Int, Int)?
        switch true {
        case brand.contains("m4"): pAndE = (4400, brand.contains("pro") || brand.contains("max") ? 2900 : 2600)
        case brand.contains("m3"): pAndE = (4050, 2748)
        case brand.contains("m2"): pAndE = (3490, 2420)
        case brand.contains("m1"): pAndE = (3200, 2064)
        default:                   pAndE = nil
        }
        guard let (pMax, eMax) = pAndE else { return [:] }

        var result: [Int: Int] = [:]
        for cluster in clusters {
            switch cluster.letter {
            case "P": result[cluster.id] = pMax
            case "E": result[cluster.id] = eMax
            default:  break
            }
        }
        return result
    }

    // MARK: - Sampling

    func read() -> CPUReaderResult {
        let usage = readPerCoreUsage()
        let load = readLoadAverage()
        let up = readUptime()
        let freq = readFrequency(clusterUsage: usage.clusters)
        let snapshot = CPUSnapshot(timestamp: Date(), total: usage.total, user: usage.user, system: usage.system)
        return CPUReaderResult(usage: usage, load: load, uptime: up, freq: freq, snapshot: snapshot)
    }

    private func readPerCoreUsage() -> CPUUsage {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0

        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &cpuInfo, &numCPUInfo)
        guard result == KERN_SUCCESS, let info = cpuInfo else { return CPUUsage() }

        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        let coreCount = Int(numCPUs)
        var totalUser: UInt64 = 0, totalSystem: UInt64 = 0, totalIdle: UInt64 = 0, totalNice: UInt64 = 0
        var coreUsages: [CPUUsage.CoreUsage] = []
        coreUsages.reserveCapacity(coreCount)

        var sumByCluster: [Int: Double] = [:]
        var countByCluster: [Int: Int] = [:]

        for i in 0..<coreCount {
            let offset = Int(CPU_STATE_MAX) * i
            let userTicks = UInt64(info[offset + Int(CPU_STATE_USER)])
            let systemTicks = UInt64(info[offset + Int(CPU_STATE_SYSTEM)])
            let idleTicks = UInt64(info[offset + Int(CPU_STATE_IDLE)])
            let niceTicks = UInt64(info[offset + Int(CPU_STATE_NICE)])

            totalUser += userTicks; totalSystem += systemTicks; totalIdle += idleTicks; totalNice += niceTicks

            var coreUsage: Double = 0
            if i < previousCoreTicks.count {
                let prev = previousCoreTicks[i]
                let dUser = userTicks - prev.user
                let dSystem = systemTicks - prev.system
                let dIdle = idleTicks - prev.idle
                let dNice = niceTicks - prev.nice
                let dTotal = dUser + dSystem + dIdle + dNice
                if dTotal > 0 { coreUsage = Double(dUser + dSystem + dNice) / Double(dTotal) * 100 }
            }

            let clusterID = clusterIDByCore[i] ?? 0
            coreUsages.append(CPUUsage.CoreUsage(id: i, usage: coreUsage, clusterID: clusterID))
            sumByCluster[clusterID, default: 0] += coreUsage
            countByCluster[clusterID, default: 0] += 1
        }

        previousCoreTicks = (0..<coreCount).map { i in
            let offset = Int(CPU_STATE_MAX) * i
            return (
                user: UInt64(info[offset + Int(CPU_STATE_USER)]),
                system: UInt64(info[offset + Int(CPU_STATE_SYSTEM)]),
                idle: UInt64(info[offset + Int(CPU_STATE_IDLE)]),
                nice: UInt64(info[offset + Int(CPU_STATE_NICE)])
            )
        }

        var overallUsage = CPUUsage()
        let dUser = totalUser - previousTotalTicks.user
        let dSystem = totalSystem - previousTotalTicks.system
        let dIdle = totalIdle - previousTotalTicks.idle
        let dTotal = dUser + dSystem + dIdle + (totalNice - previousTotalTicks.nice)

        if dTotal > 0 {
            overallUsage.user = Double(dUser) / Double(dTotal) * 100
            overallUsage.system = Double(dSystem) / Double(dTotal) * 100
            overallUsage.idle = Double(dIdle) / Double(dTotal) * 100
            overallUsage.total = overallUsage.user + overallUsage.system
        }

        previousTotalTicks = (totalUser, totalSystem, totalIdle, totalNice)
        overallUsage.perCore = coreUsages
        overallUsage.clusters = clusters.map { cluster in
            var populated = cluster
            let count = countByCluster[cluster.id] ?? 0
            populated.usage = count > 0 ? (sumByCluster[cluster.id] ?? 0) / Double(count) : 0
            return populated
        }

        return overallUsage
    }

    private func readLoadAverage() -> LoadAverage {
        var avg = [Double](repeating: 0, count: 3)
        getloadavg(&avg, 3)
        return LoadAverage(oneMinute: avg[0], fiveMinute: avg[1], fifteenMinute: avg[2])
    }

    private func readUptime() -> TimeInterval {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &bootTime, &size, nil, 0) == 0 else { return 0 }
        return Date().timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(bootTime.tv_sec)))
    }

    /// Scales each cluster's estimated ceiling by its current load. This is an
    /// approximation, not a measurement — see CPUFrequency.isEstimated.
    private func readFrequency(clusterUsage: [CPUCluster]) -> CPUFrequency {
        var freq = CPUFrequency()
        guard !maxFreqMHzByCluster.isEmpty else { return freq }

        var weightedSum = 0.0
        var weightedCores = 0

        for cluster in clusterUsage {
            guard let ceiling = maxFreqMHzByCluster[cluster.id], ceiling > 0 else { continue }
            let current = max(Int(Double(ceiling) * max(cluster.usage, 1.0) / 100.0), ceiling / 20)
            freq.perCluster[cluster.id] = current
            weightedSum += Double(current) * Double(cluster.coreIndices.count)
            weightedCores += cluster.coreIndices.count
        }

        if weightedCores > 0 { freq.allCores = Int(weightedSum / Double(weightedCores)) }
        return freq
    }
}
