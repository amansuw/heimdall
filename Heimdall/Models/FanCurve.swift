import Foundation

struct CurvePoint: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    /// X-axis value: °C for temperature curves, 0–100 for usage curves.
    var temperature: Double
    var fanSpeed: Double

    init(id: UUID = UUID(), temperature: Double, fanSpeed: Double) {
        self.id = id
        self.temperature = temperature
        self.fanSpeed = fanSpeed
    }
}

enum FanCurveInputKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case temperature
    case cpuUsage
    case gpuUsage
    case applicationCPU
    case applicationGPU

    var id: String { rawValue }

    var title: String {
        switch self {
        case .temperature: return "Temperature"
        case .cpuUsage: return "CPU Usage"
        case .gpuUsage: return "GPU Usage"
        case .applicationCPU: return "Application CPU"
        case .applicationGPU: return "Application GPU"
        }
    }

    var isTemperature: Bool { self == .temperature }
    var isUsage: Bool { !isTemperature }
    var isApplication: Bool {
        self == .applicationCPU || self == .applicationGPU
    }

    /// Inclusive X-axis domain for the curve editor and plane.
    var inputDomain: ClosedRange<Double> {
        isTemperature ? 20...110 : 0...100
    }

    var axisLabel: String {
        isTemperature ? "Temperature" : title
    }
}

struct FanCurve: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var points: [CurvePoint]
    var sensorKey: String
    var inputKind: FanCurveInputKind
    /// Primary match for application curves when non-empty.
    var bundleIdentifier: String
    /// Fallback match / CLI workers; also used as the picker subtitle.
    var processName: String
    /// What the UI shows for the selected app.
    var applicationDisplayName: String

    enum CodingKeys: String, CodingKey {
        case id, name, points, sensorKey, inputKind
        case bundleIdentifier, processName, applicationDisplayName
    }

    init(
        id: UUID = UUID(),
        name: String = "Custom",
        points: [CurvePoint]? = nil,
        sensorKey: String = "AGG_CPU_AVG",
        inputKind: FanCurveInputKind = .temperature,
        bundleIdentifier: String = "",
        processName: String = "",
        applicationDisplayName: String = ""
    ) {
        self.id = id
        self.name = name
        self.sensorKey = sensorKey
        self.inputKind = inputKind
        self.bundleIdentifier = bundleIdentifier
        self.processName = processName
        self.applicationDisplayName = applicationDisplayName
        self.points = points ?? FanCurve.defaultPoints(for: inputKind)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        points = try container.decode([CurvePoint].self, forKey: .points)
        sensorKey = try container.decodeIfPresent(String.self, forKey: .sensorKey) ?? "AGG_CPU_AVG"
        inputKind = try container.decodeIfPresent(FanCurveInputKind.self, forKey: .inputKind) ?? .temperature
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier) ?? ""
        processName = try container.decodeIfPresent(String.self, forKey: .processName) ?? ""
        applicationDisplayName = try container.decodeIfPresent(String.self, forKey: .applicationDisplayName) ?? ""
    }

    static var defaultPoints: [CurvePoint] { defaultPoints(for: .temperature) }

    static func defaultPoints(for kind: FanCurveInputKind) -> [CurvePoint] {
        switch kind {
        case .temperature:
            [
                CurvePoint(temperature: 30, fanSpeed: 0),
                CurvePoint(temperature: 45, fanSpeed: 15),
                CurvePoint(temperature: 55, fanSpeed: 30),
                CurvePoint(temperature: 65, fanSpeed: 50),
                CurvePoint(temperature: 75, fanSpeed: 75),
                CurvePoint(temperature: 85, fanSpeed: 90),
                CurvePoint(temperature: 95, fanSpeed: 100),
            ]
        case .cpuUsage, .gpuUsage, .applicationCPU, .applicationGPU:
            [
                CurvePoint(temperature: 0, fanSpeed: 0),
                CurvePoint(temperature: 25, fanSpeed: 15),
                CurvePoint(temperature: 50, fanSpeed: 40),
                CurvePoint(temperature: 75, fanSpeed: 70),
                CurvePoint(temperature: 100, fanSpeed: 100),
            ]
        }
    }

    var sortedPoints: [CurvePoint] {
        points.sorted { $0.temperature < $1.temperature }
    }

    var inputDomain: ClosedRange<Double> { inputKind.inputDomain }

    func speedForTemperature(_ temp: Double) -> Double {
        speedForInput(temp)
    }

    func speedForInput(_ input: Double) -> Double {
        let sorted = sortedPoints
        guard !sorted.isEmpty else { return 0 }
        if input <= sorted.first!.temperature { return sorted.first!.fanSpeed }
        if input >= sorted.last!.temperature { return sorted.last!.fanSpeed }

        for i in 0..<(sorted.count - 1) {
            let p1 = sorted[i]
            let p2 = sorted[i + 1]
            if input >= p1.temperature && input <= p2.temperature {
                let ratio = (input - p1.temperature) / (p2.temperature - p1.temperature)
                return p1.fanSpeed + (p2.fanSpeed - p1.fanSpeed) * ratio
            }
        }
        return sorted.last!.fanSpeed
    }

    mutating func addPoint(_ point: CurvePoint) {
        points.append(point)
    }

    mutating func removePoint(at index: Int) {
        guard points.count > 2 else { return }
        points.remove(at: index)
    }

    mutating func updatePoint(id: UUID, temperature: Double? = nil, fanSpeed: Double? = nil) {
        if let index = points.firstIndex(where: { $0.id == id }) {
            if let temp = temperature { points[index].temperature = temp }
            if let speed = fanSpeed { points[index].fanSpeed = speed }
        }
    }

    /// Switches input kind and replaces points with that kind's defaults.
    mutating func resetForInputKind(_ kind: FanCurveInputKind) {
        inputKind = kind
        points = Self.defaultPoints(for: kind)
        if !kind.isApplication {
            bundleIdentifier = ""
            processName = ""
            applicationDisplayName = ""
        }
    }
}
