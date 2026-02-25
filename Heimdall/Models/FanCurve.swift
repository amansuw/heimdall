import Foundation

struct CurvePoint: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var temperature: Double
    var fanSpeed: Double

    init(id: UUID = UUID(), temperature: Double, fanSpeed: Double) {
        self.id = id
        self.temperature = temperature
        self.fanSpeed = fanSpeed
    }
}

struct FanCurve: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var points: [CurvePoint]
    var sensorKey: String

    init(id: UUID = UUID(), name: String = "Custom", points: [CurvePoint]? = nil, sensorKey: String = "AGG_CPU_AVG") {
        self.id = id
        self.name = name
        self.sensorKey = sensorKey
        self.points = points ?? FanCurve.defaultPoints
    }

    static var defaultPoints: [CurvePoint] {
        [
            CurvePoint(temperature: 30, fanSpeed: 0),
            CurvePoint(temperature: 45, fanSpeed: 15),
            CurvePoint(temperature: 55, fanSpeed: 30),
            CurvePoint(temperature: 65, fanSpeed: 50),
            CurvePoint(temperature: 75, fanSpeed: 75),
            CurvePoint(temperature: 85, fanSpeed: 90),
            CurvePoint(temperature: 95, fanSpeed: 100),
        ]
    }

    var sortedPoints: [CurvePoint] {
        points.sorted { $0.temperature < $1.temperature }
    }

    func speedForTemperature(_ temp: Double) -> Double {
        let sorted = sortedPoints
        guard !sorted.isEmpty else { return 0 }
        if temp <= sorted.first!.temperature { return sorted.first!.fanSpeed }
        if temp >= sorted.last!.temperature { return sorted.last!.fanSpeed }

        for i in 0..<(sorted.count - 1) {
            let p1 = sorted[i]
            let p2 = sorted[i + 1]
            if temp >= p1.temperature && temp <= p2.temperature {
                let ratio = (temp - p1.temperature) / (p2.temperature - p1.temperature)
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
}
