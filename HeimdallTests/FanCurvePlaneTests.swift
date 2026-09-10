import SwiftUI
import Testing

@Suite("Fan curve plane")
struct FanCurvePlaneTests {

    private let plane = FanCurvePlane(size: CGSize(width: 900, height: 300))

    @Test func theEdgesAreTheTemperatureAndSpeedLimits() {
        #expect(plane.x(forTemperature: FanCurvePlane.minTemperature) == 0)
        #expect(plane.x(forTemperature: FanCurvePlane.maxTemperature) == 900)
        #expect(plane.y(forSpeed: 0) == 300)
        #expect(plane.y(forSpeed: 100) == 0)
    }

    /// Drawing and hit-testing share this mapping; a point drawn at a temperature
    /// must hit-test back to that temperature.
    @Test func drawingAndHitTestingAgree() {
        let temperatureDrift = stride(from: 20.0, through: 110.0, by: 0.25).map {
            abs(plane.temperature(atX: plane.x(forTemperature: $0)) - $0)
        }.max() ?? 0
        let speedDrift = stride(from: 0.0, through: 100.0, by: 0.25).map {
            abs(plane.speed(atY: plane.y(forSpeed: $0)) - $0)
        }.max() ?? 0
        #expect(temperatureDrift < 1e-9)
        #expect(speedDrift < 1e-9)
    }

    @Test func hitTestingClampsToThePlane() {
        #expect(plane.temperature(atX: -50) == FanCurvePlane.minTemperature)
        #expect(plane.temperature(atX: 5_000) == FanCurvePlane.maxTemperature)
        #expect(plane.speed(atY: -10) == 100)
        #expect(plane.speed(atY: 900) == 0)
    }

    @Test func aZeroSizedPlaneDoesNotDivideByZero() {
        let empty = FanCurvePlane(size: .zero)
        #expect(empty.temperature(atX: 10) == FanCurvePlane.minTemperature)
        #expect(empty.speed(atY: 10) == 0)
    }

    @Test func fewerThanTwoPointsDrawNothing() {
        let paths = plane.paths(for: [CurvePoint(temperature: 50, fanSpeed: 50)])
        #expect(paths.line.isEmpty)
        #expect(paths.area.isEmpty)
    }

    @Test func theAreaIsClosedDownToTheAxis() {
        let points = FanCurve.defaultPoints
        let paths = plane.paths(for: points)
        let bounds = paths.area.boundingRect
        #expect(abs(bounds.maxY - 300) < 1e-9)
        #expect(abs(bounds.minX - plane.x(forTemperature: points.first!.temperature)) < 1e-9)
        #expect(abs(bounds.maxX - plane.x(forTemperature: points.last!.temperature)) < 1e-9)
    }
}
