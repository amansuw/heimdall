import Foundation

enum FanProfileMode: String, Codable, Sendable {
    case automatic
    case manual
    case curve
}

struct FanProfile: Identifiable, Codable, Sendable {
    let id: UUID
    var name: String
    var mode: FanProfileMode
    var manualSpeedPercentage: Double?
    var curve: FanCurve?
    var isBuiltIn: Bool

    init(id: UUID = UUID(), name: String, mode: FanProfileMode, manualSpeedPercentage: Double? = nil, curve: FanCurve? = nil, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.mode = mode
        self.manualSpeedPercentage = manualSpeedPercentage
        self.curve = curve
        self.isBuiltIn = isBuiltIn
    }

    static let builtInProfiles: [FanProfile] = [
        FanProfile(name: "Silent", mode: .curve, curve: FanCurve(name: "Silent", points: [
            CurvePoint(temperature: 40, fanSpeed: 0),
            CurvePoint(temperature: 60, fanSpeed: 0),
            CurvePoint(temperature: 75, fanSpeed: 25),
            CurvePoint(temperature: 85, fanSpeed: 50),
            CurvePoint(temperature: 95, fanSpeed: 80),
            CurvePoint(temperature: 100, fanSpeed: 100),
        ]), isBuiltIn: true),
        FanProfile(name: "Default", mode: .automatic, isBuiltIn: true),
        FanProfile(name: "Balanced", mode: .curve, curve: FanCurve(name: "Balanced"), isBuiltIn: true),
        FanProfile(name: "Performance", mode: .curve, curve: FanCurve(name: "Performance", points: [
            CurvePoint(temperature: 30, fanSpeed: 15),
            CurvePoint(temperature: 45, fanSpeed: 30),
            CurvePoint(temperature: 55, fanSpeed: 50),
            CurvePoint(temperature: 65, fanSpeed: 70),
            CurvePoint(temperature: 75, fanSpeed: 90),
            CurvePoint(temperature: 80, fanSpeed: 100),
        ]), isBuiltIn: true),
        FanProfile(name: "Max", mode: .manual, manualSpeedPercentage: 100, isBuiltIn: true),
    ]
}
