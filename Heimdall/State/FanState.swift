import Foundation

enum FanControlMode: String, CaseIterable, Identifiable, Sendable {
    case automatic = "Automatic"
    case manual = "Manual"
    case curve = "Fan Curve"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .automatic: return "gearshape"
        case .manual: return "slider.horizontal.3"
        case .curve: return "chart.xyaxis.line"
        }
    }
}

@Observable
class FanState {
    var fans: [FanInfo] = []
    var controlMode: FanControlMode = .automatic
    var manualSpeedPercentage: Double = 50.0
    var isControlActive = false
    var hasWriteAccess = false
    var isRequestingAccess = false
    var isYielding = false
    var isCurveCooldownActive = false
    var activeCurve: FanCurve?

    var averageSpeedPercentage: Double {
        let pairs = fans.compactMap { fan -> Double? in
            guard fan.maxSpeed > fan.minSpeed else { return nil }
            let normalized = (fan.currentSpeed - fan.minSpeed) / (fan.maxSpeed - fan.minSpeed)
            return max(0, min(1, normalized)) * 100.0
        }
        guard !pairs.isEmpty else { return 0 }
        return pairs.reduce(0, +) / Double(pairs.count)
    }

    var unifiedSpeedLabel: String {
        let labels = Set(fans.map(\.selectedSpeedLabel))
        return labels.count == 1 ? (labels.first ?? "Auto") : ""
    }
}
