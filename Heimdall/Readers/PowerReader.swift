import Foundation

// MARK: - Model

/// One "Energy Model" channel from an IOReport sample delta.
struct EnergyReading: Sendable, Equatable {
    let channel: String
    let unit: String
    let value: Int64

    /// Energy in joules, or nil for a unit this does not recognise. Units differ
    /// between channels on the same Mac — on an M3 Pro, CPU Energy is reported in
    /// mJ and GPU Energy in nJ — so every reading is converted on its own.
    var joules: Double? {
        let amount = Double(value)
        switch unit.trimmingCharacters(in: .whitespaces) {
        case "J": return amount
        case "mJ": return amount / 1e3
        case "uJ", "µJ": return amount / 1e6
        case "nJ": return amount / 1e9
        default: return nil
        }
    }
}

/// One absolute Energy Model counter, plus the mach time of its last publication.
///
/// The CPU and Neural Engine counters on Apple Silicon do not tick every poll.
/// They sit still, then publish a lump of energy with a new mach timestamp.
/// Dividing that lump by the poll interval (about 2s) turns a minute at 2 W
/// into one sample at 50 W, which the chart draws as a spike.
struct ChannelSample: Sendable, Equatable {
    let unit: String
    let energy: Int64
    /// Mach-absolute ticks. 0 when the sample did not carry a timestamp.
    let machTicks: UInt64
}

/// Average SoC power, in watts, over one sampling interval.
struct SoCPower: Sendable, Equatable {
    var cpu: Double?
    var gpu: Double?
    /// The Neural Engine.
    var ane: Double?
    /// DRAM, which Apple Silicon reports alongside the SoC rails.
    var memory: Double?
    /// Whole-machine draw from the SMC key PSTR, filled in by the monitor. It
    /// updates every read, unlike the SoC rails.
    var system: Double?

    /// How far back `cpu` / `gpu` / `ane` actually apply. Zero means this
    /// sample only: the counter did not publish, so history behind it stays put.
    var cpuWindow: TimeInterval = 0
    var gpuWindow: TimeInterval = 0
    var aneWindow: TimeInterval = 0

    /// Every Apple Silicon Mac has a Neural Engine, and macOS powers it down when
    /// nothing is using it, so an idle one draws nothing and reads exactly 0. Showing
    /// that as "0 mW" looks like the part is missing, so views say "Idle" instead.
    /// False when there is no reading at all.
    var neuralEngineIsIdle: Bool {
        guard let ane else { return false }
        return ane < 0.0005
    }

    /// CPU + GPU + Neural Engine: what powermetrics calls combined power.
    /// Nil without a CPU reading: GPU alone is not the SoC, and summing it
    /// would pass off a fraction of the chip as the whole.
    var combined: Double? {
        guard let cpu else { return nil }
        return cpu + (gpu ?? 0) + (ane ?? 0)
    }

    /// A lump that covers more than this is an average over minutes, not a
    /// reading. It is dropped rather than painted as a flat band.
    static let maxLiveWindow: TimeInterval = 90

    init(cpu: Double? = nil, gpu: Double? = nil, ane: Double? = nil, memory: Double? = nil,
         system: Double? = nil,
         cpuWindow: TimeInterval = 0, gpuWindow: TimeInterval = 0, aneWindow: TimeInterval = 0) {
        self.cpu = cpu
        self.gpu = gpu
        self.ane = ane
        self.memory = memory
        self.system = system
        self.cpuWindow = cpuWindow
        self.gpuWindow = gpuWindow
        self.aneWindow = aneWindow
    }

    /// Converts one sample delta into watts. Channel names differ between chip
    /// generations, so each rail tries its usual name first and then a broader match.
    /// The whole delta is assumed to have arrived during `interval`.
    init(readings: [EnergyReading], interval: TimeInterval) {
        func watts(_ candidates: [(EnergyReading) -> Bool]) -> (Double?, TimeInterval) {
            guard interval > 0 else { return (nil, 0) }
            for matches in candidates {
                let hits = readings.filter(matches)
                guard !hits.isEmpty else { continue }
                let joules = hits.compactMap(\.joules)
                guard joules.count == hits.count else { return (nil, 0) }
                // A counter that wrapped between samples yields a negative delta.
                return (max(joules.reduce(0, +), 0) / interval, interval)
            }
            return (nil, 0)
        }

        let cpu = watts([{ $0.channel == "CPU Energy" },
                         { $0.channel == "ECPU" || $0.channel == "PCPU" }])
        let gpu = watts([{ $0.channel == "GPU Energy" },
                         { $0.channel == "GPU" }])
        let ane = watts([{ $0.channel == "ANE" },
                         { $0.channel.hasPrefix("ANE") && !$0.channel.contains("SRAM") }])
        let memory = watts([{ $0.channel == "DRAM" }])
        self.init(
            cpu: cpu.0, gpu: gpu.0, ane: ane.0, memory: memory.0,
            cpuWindow: cpu.1, gpuWindow: gpu.1, aneWindow: ane.1
        )
    }

    /// Watts from two absolute samples. A rail that did not publish has no
    /// reading and a zero window: a counter that is not moving says nothing
    /// about the load. On an M3 Max under macOS 27, CPU Energy and ANE0 stayed
    /// frozen through full CPU and Neural Engine load, and reading that as 0 W
    /// is what put "Idle" on a busy Neural Engine.
    ///
    /// `silence` is seconds since that channel last changed, measured on the wall
    /// clock. CPU and ANE on this SoC often publish with a mach timestamp that
    /// does not move, so the tick span collapses to the poll interval and a
    /// minute of load becomes one spike. The longer of the two clocks is the
    /// window the chart repaints.
    init(previous: [String: ChannelSample], current: [String: ChannelSample],
         wallInterval: TimeInterval, ticksPerSecond: Double,
         silence: [String: TimeInterval] = [:]) {
        func rail(_ candidates: [(String) -> Bool]) -> (Double?, TimeInterval) {
            for matches in candidates {
                let names = current.keys.filter(matches)
                guard !names.isEmpty else { continue }
                var joules = 0.0
                var window = 0.0
                var published = false
                for name in names {
                    guard let now = current[name], let then = previous[name] else { continue }
                    let unchanged = now.energy == then.energy && now.machTicks == then.machTicks
                    if unchanged { continue }
                    guard let converted = EnergyReading(
                        channel: name, unit: now.unit, value: max(now.energy - then.energy, 0)
                    ).joules else { return (nil, 0) }
                    published = true
                    joules += converted
                    let ticks = Self.span(from: then.machTicks, to: now.machTicks,
                                          wallInterval: wallInterval, ticksPerSecond: ticksPerSecond)
                    window = max(window, ticks, silence[name] ?? wallInterval)
                }
                guard published, window > 0, window <= Self.maxLiveWindow else { return (nil, 0) }
                return (joules / window, window)
            }
            return (nil, 0)
        }

        let cpu = rail([{ $0 == "CPU Energy" }, { $0 == "ECPU" || $0 == "PCPU" }])
        let gpu = rail([{ $0 == "GPU Energy" }, { $0 == "GPU" }])
        let ane = rail([{ $0 == "ANE" }, { $0.hasPrefix("ANE") && !$0.contains("SRAM") }])
        let memory = rail([{ $0 == "DRAM" }])
        self.init(
            cpu: cpu.0, gpu: gpu.0, ane: ane.0, memory: memory.0,
            cpuWindow: cpu.1, gpuWindow: gpu.1, aneWindow: ane.1
        )
    }

    private static func span(from previous: UInt64, to current: UInt64,
                             wallInterval: TimeInterval, ticksPerSecond: Double) -> TimeInterval {
        guard previous > 0, current > previous, ticksPerSecond > 0 else { return wallInterval }
        return Double(current - previous) / ticksPerSecond
    }
}

struct PowerSnapshot: Sendable, TimestampedSample {
    var timestamp: Date
    var cpu: Double?
    var gpu: Double?
    var ane: Double?
    var system: Double?
}

// MARK: - IOReport

/// Reads SoC energy from IOReport's "Energy Model" group — the counters
/// powermetrics uses — without root.
///
/// IOReport is a private library, so it is opened with dlopen and each function is
/// looked up by name. When any of that fails (an Intel Mac, a virtual machine, or a
/// macOS release that changes it), or the group has no channels, `read()` returns
/// nil and the app hides power instead of showing zeros.
///
/// Used only from the monitor's fast queue.
final class PowerReader {
    private typealias CopyChannelsInGroup = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubscription = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> OpaquePointer?
    private typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias SimpleGetIntegerValue = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias ChannelGetString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?

    private struct Functions {
        let createSamples: CreateSamples
        let simpleGetIntegerValue: SimpleGetIntegerValue
        let channelName: ChannelGetString
        let unitLabel: ChannelGetString
    }

    private let functions: Functions?
    private let subscription: OpaquePointer?
    private let subscribedChannels: CFMutableDictionary?
    private let ticksPerSecond: Double
    private var previous: (channels: [String: ChannelSample], time: Date)?
    /// Wall time of the last sample in which each channel's counter moved.
    private var lastChange: [String: Date] = [:]
    /// Each rail's last published watts. A counter that skips a poll or two
    /// keeps its value for `holdFor` instead of flickering to "—".
    private var heldCPU: (watts: Double, at: Date)?
    private var heldGPU: (watts: Double, at: Date)?
    private var heldANE: (watts: Double, at: Date)?

    static let holdFor: TimeInterval = 20

    var isAvailable: Bool { functions != nil }

    init() {
        func symbol<T>(_ library: UnsafeMutableRawPointer, _ name: String, as _: T.Type) -> T? {
            dlsym(library, name).map { unsafeBitCast($0, to: T.self) }
        }

        guard let library = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW),
              let copyChannels = symbol(library, "IOReportCopyChannelsInGroup", as: CopyChannelsInGroup.self),
              let createSubscription = symbol(library, "IOReportCreateSubscription", as: CreateSubscription.self),
              let createSamples = symbol(library, "IOReportCreateSamples", as: CreateSamples.self),
              let simpleGetIntegerValue = symbol(library, "IOReportSimpleGetIntegerValue", as: SimpleGetIntegerValue.self),
              let channelName = symbol(library, "IOReportChannelGetChannelName", as: ChannelGetString.self),
              let unitLabel = symbol(library, "IOReportChannelGetUnitLabel", as: ChannelGetString.self),
              let channels = copyChannels("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue()
        else {
            functions = nil
            subscription = nil
            subscribedChannels = nil
            ticksPerSecond = 0
            return
        }

        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let sub = createSubscription(nil, channels, &subscribed, 0, nil),
              let subbed = subscribed?.takeRetainedValue() else {
            functions = nil
            subscription = nil
            subscribedChannels = nil
            ticksPerSecond = 0
            return
        }

        functions = Functions(
            createSamples: createSamples,
            simpleGetIntegerValue: simpleGetIntegerValue,
            channelName: channelName,
            unitLabel: unitLabel
        )
        subscription = sub
        subscribedChannels = subbed
        var timebase = mach_timebase_info_data_t()
        if mach_timebase_info(&timebase) == 0, timebase.numer > 0 {
            let nanosPerTick = Double(timebase.numer) / Double(timebase.denom)
            ticksPerSecond = 1e9 / nanosPerTick
        } else {
            ticksPerSecond = 0
        }
    }

    /// Average power since the previous call. The first call only primes the
    /// baseline and returns nil.
    func read() -> SoCPower? {
        guard let functions, let subscription, let subscribedChannels,
              let sample = functions.createSamples(subscription, subscribedChannels, nil)?.takeRetainedValue()
        else { return nil }

        let now = Date()
        let channels = Self.channels(in: sample, functions: functions)
        let last = previous
        previous = (channels, now)
        guard let last else {
            lastChange = channels.mapValues { _ in now }
            return nil
        }

        let interval = now.timeIntervalSince(last.time)
        guard interval > 0 else { return nil }

        var silence: [String: TimeInterval] = [:]
        for (name, sample) in channels {
            let changed: Bool
            if let before = last.channels[name] {
                changed = before.energy != sample.energy || before.machTicks != sample.machTicks
            } else {
                changed = true
            }
            guard changed else { continue }
            silence[name] = now.timeIntervalSince(lastChange[name] ?? last.time)
            lastChange[name] = now
        }

        var power = SoCPower(previous: last.channels, current: channels,
                             wallInterval: interval, ticksPerSecond: ticksPerSecond,
                             silence: silence)
        power.cpu = Self.hold(power.cpu, in: &heldCPU, now: now)
        power.gpu = Self.hold(power.gpu, in: &heldGPU, now: now)
        power.ane = Self.hold(power.ane, in: &heldANE, now: now)
        // An idle Neural Engine may not publish at all. CPU Energy comes from
        // the same power-manager driver, so while it is live, a silent ANE
        // counter means the engine is off. When both are silent, nothing is known.
        if power.ane == nil, power.cpu != nil, channels.keys.contains(where: { $0.hasPrefix("ANE") }) {
            power.ane = 0
        }
        return power.gpu == nil && power.combined == nil && power.memory == nil ? nil : power
    }

    private static func hold(_ watts: Double?, in held: inout (watts: Double, at: Date)?, now: Date) -> Double? {
        if let watts {
            held = (watts, now)
            return watts
        }
        guard let last = held, now.timeIntervalSince(last.at) <= holdFor else {
            held = nil
            return nil
        }
        return last.watts
    }

    private static func channels(in sample: CFDictionary, functions: Functions) -> [String: ChannelSample] {
        guard let items = (sample as NSDictionary)["IOReportChannels"] as? [NSDictionary] else { return [:] }
        var channels: [String: ChannelSample] = [:]
        channels.reserveCapacity(items.count)
        for item in items {
            let channel = item as CFDictionary
            guard let name = functions.channelName(channel)?.takeUnretainedValue() as String?,
                  let unit = functions.unitLabel(channel)?.takeUnretainedValue() as String?
            else { continue }
            var ticks: UInt64 = 0
            if let data = item["RawElements"] as? Data, data.count >= 40 {
                ticks = data.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt64.self) }
            }
            channels[name] = ChannelSample(
                unit: unit,
                energy: functions.simpleGetIntegerValue(channel, 0),
                machTicks: ticks
            )
        }
        return channels
    }
}
