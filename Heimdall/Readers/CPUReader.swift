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
    private(set) var eCores: Int = 0
    private(set) var pCores: Int = 0
    private(set) var maxPFreqMHz: Int = 0
    private(set) var maxEFreqMHz: Int = 0

    private var previousCoreTicks: [(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)] = []
    private var previousTotalTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) = (0, 0, 0, 0)

    init() {
        detectTopology()
    }

    private func detectTopology() {
        totalCores = ProcessInfo.processInfo.processorCount

        var eCount: Int32 = 0
        var pCount: Int32 = 0
        var size = MemoryLayout<Int32>.size

        if sysctlbyname("hw.perflevel1.logicalcpu", &eCount, &size, nil, 0) == 0 {
            eCores = Int(eCount)
        }
        size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.logicalcpu", &pCount, &size, nil, 0) == 0 {
            pCores = Int(pCount)
        }

        if eCores == 0 && pCores == 0 { pCores = totalCores }

        let (pMax, eMax) = resolveMaxFrequencies()
        maxPFreqMHz = pMax
        maxEFreqMHz = eMax
    }

    private func resolveMaxFrequencies() -> (Int, Int) {
        var maxFreq: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.cpufrequency_max", &maxFreq, &size, nil, 0) == 0, maxFreq > 0 {
            let mhz = Int(maxFreq / 1_000_000)
            return (mhz, mhz)
        }

        var brandBuf = [CChar](repeating: 0, count: 256)
        var brandSize = brandBuf.count
        sysctlbyname("machdep.cpu.brand_string", &brandBuf, &brandSize, nil, 0)
        let brand = String(cString: brandBuf).lowercased()

        switch true {
        case brand.contains("m4 max"):   return (4400, 2900)
        case brand.contains("m4 pro"):   return (4400, 2900)
        case brand.contains("m4"):       return (4400, 2600)
        case brand.contains("m3 max"):   return (4050, 2748)
        case brand.contains("m3 pro"):   return (4050, 2748)
        case brand.contains("m3"):       return (4050, 2748)
        case brand.contains("m2 max"):   return (3490, 2420)
        case brand.contains("m2 pro"):   return (3490, 2420)
        case brand.contains("m2 ultra"): return (3490, 2420)
        case brand.contains("m2"):       return (3490, 2420)
        case brand.contains("m1 max"):   return (3200, 2064)
        case brand.contains("m1 pro"):   return (3200, 2064)
        case brand.contains("m1 ultra"): return (3200, 2064)
        case brand.contains("m1"):       return (3200, 2064)
        default:                         return (0, 0)
        }
    }

    func read() -> CPUReaderResult {
        let usage = readPerCoreUsage()
        let load = readLoadAverage()
        let up = readUptime()
        let freq = readFrequency(pUsage: usage.performanceCores, eUsage: usage.efficiencyCores)
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
        var eTotal: Double = 0, pTotal: Double = 0
        var eCount = 0, pCount = 0

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

            let isEfficiency = i >= pCores && eCores > 0
            coreUsages.append(CPUUsage.CoreUsage(id: i, usage: coreUsage, isEfficiency: isEfficiency))

            if isEfficiency { eTotal += coreUsage; eCount += 1 }
            else { pTotal += coreUsage; pCount += 1 }
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
        overallUsage.efficiencyCores = eCount > 0 ? eTotal / Double(eCount) : 0
        overallUsage.performanceCores = pCount > 0 ? pTotal / Double(pCount) : 0

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

    private func readFrequency(pUsage: Double, eUsage: Double) -> CPUFrequency {
        var freq = CPUFrequency()
        if maxPFreqMHz > 0 {
            let pCurrent = Int(Double(maxPFreqMHz) * max(pUsage, 1.0) / 100.0)
            freq.performanceCores = max(pCurrent, maxPFreqMHz / 20)
        }
        if maxEFreqMHz > 0 {
            let eCurrent = Int(Double(maxEFreqMHz) * max(eUsage, 1.0) / 100.0)
            freq.efficiencyCores = max(eCurrent, maxEFreqMHz / 20)
        }
        let totalCoreCount = pCores + eCores
        if totalCoreCount > 0 && (freq.performanceCores > 0 || freq.efficiencyCores > 0) {
            let pContrib = Double(max(freq.performanceCores, 0)) * Double(pCores)
            let eContrib = Double(max(freq.efficiencyCores, 0)) * Double(eCores)
            freq.allCores = Int((pContrib + eContrib) / Double(totalCoreCount))
        } else if freq.performanceCores > 0 {
            freq.allCores = freq.performanceCores
        } else {
            freq.allCores = freq.efficiencyCores
        }
        return freq
    }
}
