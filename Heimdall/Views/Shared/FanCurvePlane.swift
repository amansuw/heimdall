import SwiftUI

/// The temperature × fan-speed plane every fan-curve view draws on. The curve
/// editor, its profile cards and the Dashboard preview each carried their own
/// copy of `(t - 20) / 90`; sharing one mapping means a point cannot be drawn in
/// one place and hit-tested somewhere else.
struct FanCurvePlane {
    static let minTemperature: Double = 20
    static let maxTemperature: Double = 110
    static var temperatureSpan: Double { maxTemperature - minTemperature }

    let size: CGSize

    func x(forTemperature celsius: Double) -> CGFloat {
        CGFloat((celsius - Self.minTemperature) / Self.temperatureSpan) * size.width
    }

    func y(forSpeed percent: Double) -> CGFloat {
        size.height - CGFloat(percent / 100) * size.height
    }

    func position(of point: CurvePoint) -> CGPoint {
        CGPoint(x: x(forTemperature: point.temperature), y: y(forSpeed: point.fanSpeed))
    }

    /// Temperature under a view-space x, clamped to the plane.
    func temperature(atX x: CGFloat) -> Double {
        guard size.width > 0 else { return Self.minTemperature }
        let fraction = min(max(Double(x / size.width), 0), 1)
        return Self.minTemperature + fraction * Self.temperatureSpan
    }

    /// Fan speed under a view-space y, clamped to 0–100 %.
    func speed(atY y: CGFloat) -> Double {
        guard size.height > 0 else { return 0 }
        return min(max(Double(1 - y / size.height) * 100, 0), 100)
    }

    /// The curve's line and the closed area beneath it; both empty below two points.
    func paths(for sortedPoints: [CurvePoint]) -> (line: Path, area: Path) {
        guard sortedPoints.count >= 2, let first = sortedPoints.first, let last = sortedPoints.last else {
            return (Path(), Path())
        }
        var line = Path()
        line.move(to: position(of: first))
        for point in sortedPoints.dropFirst() { line.addLine(to: position(of: point)) }

        var area = line
        area.addLine(to: CGPoint(x: x(forTemperature: last.temperature), y: size.height))
        area.addLine(to: CGPoint(x: x(forTemperature: first.temperature), y: size.height))
        area.closeSubpath()
        return (line, area)
    }
}

/// Read-only thumbnail of a fan curve.
struct FanCurvePreview: View {
    let curve: FanCurve
    var lineOpacity: Double = 0.75
    var fillOpacity: Double = 0.15
    var lineWidth: CGFloat = 1.5

    var body: some View {
        Canvas { context, size in
            let paths = FanCurvePlane(size: size).paths(for: curve.sortedPoints)
            context.fill(paths.area, with: .color(.blue.opacity(fillOpacity)))
            context.stroke(paths.line, with: .color(.blue.opacity(lineOpacity)), lineWidth: lineWidth)
        }
    }
}
