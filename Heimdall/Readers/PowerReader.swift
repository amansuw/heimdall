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

/// Average SoC power, in watts, over one sampling interval.
struct SoCPower: Sendable, Equatable {
    var cpu: Double?
    var gpu: Double?
    /// The Neural Engine.
    var ane: Double?
    /// DRAM, which Apple Silicon reports alongside the SoC rails.
    var memory: Double?

    /// Every Apple Silicon Mac has a Neural Engine, and macOS powers it down when
    /// nothing is using it, so an idle one draws nothing and reads exactly 0. Showing
    /// that as "0 mW" looks like the part is missing, so views say "Idle" instead.
    /// False when there is no reading at all.
    var neuralEngineIsIdle: Bool {
        guard let ane else { return false }
        return ane < 0.0005
    }

    /// CPU + GPU + Neural Engine: what powermetrics calls combined power.
    var combined: Double? {
        let parts = [cpu, gpu, ane].compactMap { $0 }
        return parts.isEmpty ? nil : parts.reduce(0, +)
    }

    init(cpu: Double? = nil, gpu: Double? = nil, ane: Double? = nil, memory: Double? = nil) {
        self.cpu = cpu
        self.gpu = gpu
        self.ane = ane
        self.memory = memory
    }

    /// Converts one sample delta into watts. Channel names differ between chip
    /// generations, so each rail tries its usual name first and then a broader match.
    init(readings: [EnergyReading], interval: TimeInterval) {
        func watts(_ candidates: [(EnergyReading) -> Bool]) -> Double? {
            guard interval > 0 else { return nil }
            for matches in candidates {
                let hits = readings.filter(matches)
                guard !hits.isEmpty else { continue }
                let joules = hits.compactMap(\.joules)
                guard joules.count == hits.count else { return nil }
                // A counter that wrapped between samples yields a negative delta.
                return max(joules.reduce(0, +), 0) / interval
            }
            return nil
        }

        self.init(
            cpu: watts([{ $0.channel == "CPU Energy" },
                        { $0.channel == "ECPU" || $0.channel == "PCPU" }]),
            gpu: watts([{ $0.channel == "GPU Energy" },
                        { $0.channel == "GPU" }]),
            ane: watts([{ $0.channel == "ANE" },
                        { $0.channel.hasPrefix("ANE") && !$0.channel.contains("SRAM") }]),
            memory: watts([{ $0.channel == "DRAM" }])
        )
    }
}

struct PowerSnapshot: Sendable, TimestampedSample {
    let timestamp: Date
    let cpu: Double?
    let gpu: Double?
    let ane: Double?
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
    private typealias CreateSamplesDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias SimpleGetIntegerValue = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias ChannelGetString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?

    private struct Functions {
        let createSamples: CreateSamples
        let createSamplesDelta: CreateSamplesDelta
        let simpleGetIntegerValue: SimpleGetIntegerValue
        let channelName: ChannelGetString
        let unitLabel: ChannelGetString
    }

    private let functions: Functions?
    private let subscription: OpaquePointer?
    private let subscribedChannels: CFMutableDictionary?
    private var previous: (sample: CFDictionary, time: Date)?

    var isAvailable: Bool { functions != nil }

    init() {
        func symbol<T>(_ library: UnsafeMutableRawPointer, _ name: String, as _: T.Type) -> T? {
            dlsym(library, name).map { unsafeBitCast($0, to: T.self) }
        }

        guard let library = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW),
              let copyChannels = symbol(library, "IOReportCopyChannelsInGroup", as: CopyChannelsInGroup.self),
              let createSubscription = symbol(library, "IOReportCreateSubscription", as: CreateSubscription.self),
              let createSamples = symbol(library, "IOReportCreateSamples", as: CreateSamples.self),
              let createSamplesDelta = symbol(library, "IOReportCreateSamplesDelta", as: CreateSamplesDelta.self),
              let simpleGetIntegerValue = symbol(library, "IOReportSimpleGetIntegerValue", as: SimpleGetIntegerValue.self),
              let channelName = symbol(library, "IOReportChannelGetChannelName", as: ChannelGetString.self),
              let unitLabel = symbol(library, "IOReportChannelGetUnitLabel", as: ChannelGetString.self),
              let channels = copyChannels("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue()
        else {
            functions = nil
            subscription = nil
            subscribedChannels = nil
            return
        }

        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let sub = createSubscription(nil, channels, &subscribed, 0, nil),
              let subbed = subscribed?.takeRetainedValue() else {
            functions = nil
            subscription = nil
            subscribedChannels = nil
            return
        }

        functions = Functions(
            createSamples: createSamples,
            createSamplesDelta: createSamplesDelta,
            simpleGetIntegerValue: simpleGetIntegerValue,
            channelName: channelName,
            unitLabel: unitLabel
        )
        subscription = sub
        subscribedChannels = subbed
    }

    /// Average power since the previous call. The first call only primes the
    /// baseline and returns nil.
    func read() -> SoCPower? {
        guard let functions, let subscription, let subscribedChannels,
              let sample = functions.createSamples(subscription, subscribedChannels, nil)?.takeRetainedValue()
        else { return nil }

        let now = Date()
        let last = previous
        previous = (sample, now)
        guard let last else { return nil }

        let interval = now.timeIntervalSince(last.time)
        guard interval > 0,
              let delta = functions.createSamplesDelta(last.sample, sample, nil)?.takeRetainedValue(),
              let items = (delta as NSDictionary)["IOReportChannels"] as? [NSDictionary]
        else { return nil }

        let readings = items.compactMap { item -> EnergyReading? in
            let channel = item as CFDictionary
            guard let name = functions.channelName(channel)?.takeUnretainedValue() as String?,
                  let unit = functions.unitLabel(channel)?.takeUnretainedValue() as String?
            else { return nil }
            return EnergyReading(channel: name, unit: unit, value: functions.simpleGetIntegerValue(channel, 0))
        }

        let power = SoCPower(readings: readings, interval: interval)
        return power.combined == nil && power.memory == nil ? nil : power
    }
}
