#!/usr/bin/env swift
//
// Loads a small convolution network onto the Neural Engine and checks the
// same IOReport energy counters Heimdall uses for CPU Power, GPU Power, and
// the Neural Engine card.
//
// Usage:
//   swift scripts/test-neural-engine.swift
//   swift scripts/test-neural-engine.swift 20
//
// The number is how many seconds to keep the engine busy. Default is 8.
// While it runs, `sudo powermetrics -i 1000 -n 8 --samplers cpu_power,gpu_power,ane_power`
// shows Apple's estimated watts. Heimdall does not use that tool. It reads
// IOReport without root.

import CoreML
import Foundation

struct EnergyCounter {
    let channel: String
    let unit: String
    let value: Int64
}

enum EnergyModel {
    private typealias CopyChannels = @convention(c) (
        CFString?, CFString?, UInt64, UInt64, UInt64
    ) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubscription = @convention(c) (
        UnsafeMutableRawPointer?, CFMutableDictionary,
        UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?
    ) -> OpaquePointer?
    private typealias CreateSamples = @convention(c) (
        OpaquePointer, CFMutableDictionary, CFTypeRef?
    ) -> Unmanaged<CFDictionary>?
    private typealias GetInteger = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias GetString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?

    private static func symbol<T>(_ library: UnsafeMutableRawPointer, _ name: String) -> T? {
        dlsym(library, name).map { unsafeBitCast($0, to: T.self) }
    }

    static func read() -> [EnergyCounter]? {
        guard let library = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW),
              let copyChannels: CopyChannels = symbol(library, "IOReportCopyChannelsInGroup"),
              let createSubscription: CreateSubscription = symbol(library, "IOReportCreateSubscription"),
              let createSamples: CreateSamples = symbol(library, "IOReportCreateSamples"),
              let getInteger: GetInteger = symbol(library, "IOReportSimpleGetIntegerValue"),
              let channelName: GetString = symbol(library, "IOReportChannelGetChannelName"),
              let unitLabel: GetString = symbol(library, "IOReportChannelGetUnitLabel"),
              let channels = copyChannels("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue()
        else { return nil }

        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = createSubscription(nil, channels, &subscribed, 0, nil),
              let subscribedChannels = subscribed?.takeRetainedValue(),
              let sample = createSamples(subscription, subscribedChannels, nil)?.takeRetainedValue(),
              let items = (sample as NSDictionary)["IOReportChannels"] as? [NSDictionary]
        else { return nil }

        return items.compactMap { item in
            let channel = item as CFDictionary
            guard let name = channelName(channel)?.takeUnretainedValue() as String?,
                  let unit = unitLabel(channel)?.takeUnretainedValue() as String?
            else { return nil }
            let keep = name == "CPU Energy" || name == "GPU Energy"
                || (name.hasPrefix("ANE") && !name.contains("SRAM"))
            guard keep else { return nil }
            return EnergyCounter(channel: name, unit: unit, value: getInteger(channel, 0))
        }
    }
}

func deviceName(_ device: MLComputeDevice) -> String {
    switch device {
    case .cpu: return "CPU"
    case .gpu: return "GPU"
    case .neuralEngine: return "Neural Engine"
    @unknown default: return "unknown"
    }
}

let seconds: Double = {
    guard CommandLine.arguments.count > 1 else { return 8 }
    guard let value = Double(CommandLine.arguments[1]), value > 0 else {
        fputs("usage: swift scripts/test-neural-engine.swift [seconds]\n", stderr)
        exit(2)
    }
    return value
}()

let modelURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("ane-load.mlmodel")
guard FileManager.default.fileExists(atPath: modelURL.path) else {
    fputs("missing model next to this script: \(modelURL.path)\n", stderr)
    exit(1)
}

let compiled = try MLModel.compileModel(at: modelURL)
let config = MLModelConfiguration()
config.computeUnits = .cpuAndNeuralEngine

let plan = try await MLComputePlan.load(contentsOf: compiled, configuration: config)
var scheduledOnNeuralEngine = false
switch plan.modelStructure {
case .neuralNetwork(let network):
    for layer in network.layers {
        let preferred = plan.deviceUsage(for: layer).map { deviceName($0.preferred) } ?? "unknown"
        if preferred == "Neural Engine" { scheduledOnNeuralEngine = true }
        print("\(layer.name) \(layer.type): \(preferred)")
    }
default:
    fputs("the model compiled, but Core ML did not expose a layer plan\n", stderr)
    exit(1)
}

let model = try MLModel(contentsOf: compiled, configuration: config)
guard let constraint = model.modelDescription.inputDescriptionsByName["image"]?.multiArrayConstraint else {
    fputs("model has no image input\n", stderr)
    exit(1)
}
let array = try MLMultiArray(shape: constraint.shape, dataType: constraint.dataType)
for index in 0..<min(array.count, 4096) {
    array[index] = 0.25
}
let input = try MLDictionaryFeatureProvider(dictionary: [
    "image": MLFeatureValue(multiArray: array),
])

let before = EnergyModel.read()
let started = Date()
var predictions = 0
while Date().timeIntervalSince(started) < seconds {
    _ = try await model.prediction(from: input)
    predictions += 1
}
let elapsed = Date().timeIntervalSince(started)
let after = EnergyModel.read()

print("predictions: \(predictions) in \(String(format: "%.1f", elapsed))s")

guard let before, let after else {
    fputs("IOReport Energy Model is unavailable, so Heimdall hides power on this machine.\n", stderr)
    exit(0)
}

let afterByChannel = Dictionary(uniqueKeysWithValues: after.map { ($0.channel, $0) })
var aneDelta = Int64(0)
var cpuDelta = Int64(0)
print("energy counters, same ones Heimdall reads:")
for start in before {
    guard let end = afterByChannel[start.channel] else { continue }
    let delta = end.value - start.value
    if start.channel == "CPU Energy" { cpuDelta = delta }
    if start.channel.hasPrefix("ANE") { aneDelta += delta }
    print("  \(start.channel)  \(delta) \(start.unit)")
}

if scheduledOnNeuralEngine && aneDelta == 0 {
    print("The convolutions were scheduled on the Neural Engine, and the ANE counter did not move.")
    if cpuDelta == 0 {
        print("CPU Energy did not move either. It comes from the same power-manager driver as ANE,")
        print("so macOS is not publishing either counter. Heimdall shows both as — instead of Idle.")
        print("GPU Energy is reported by the GPU driver, which is why that card still updates.")
    } else {
        print("CPU Energy moved, so the driver is publishing and the ANE reading is a real 0.")
    }
    print("For estimated watts while this script runs, in another terminal:")
    print("  sudo powermetrics -i 1000 -n \(Int(seconds.rounded(.up))) --samplers cpu_power,gpu_power,ane_power")
} else if aneDelta > 0 {
    print("The ANE counter moved. Heimdall should leave Idle on the next sample.")
} else {
    print("Core ML did not place the layers on the Neural Engine.")
}
