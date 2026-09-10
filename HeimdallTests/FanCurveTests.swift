import Foundation
import Testing

@Suite("Fan curve")
struct FanCurveTests {

    private func curve(_ pairs: [(Double, Double)]) -> FanCurve {
        FanCurve(points: pairs.map { CurvePoint(temperature: $0.0, fanSpeed: $0.1) })
    }

    @Test func interpolatesLinearlyBetweenPoints() {
        let c = curve([(40, 20), (60, 60)])
        #expect(c.speedForTemperature(50) == 40)
        #expect(c.speedForTemperature(45) == 30)
    }

    @Test func holdsTheEndSpeedsOutsideTheCurve() {
        let c = curve([(40, 20), (60, 60)])
        #expect(c.speedForTemperature(-10) == 20)
        #expect(c.speedForTemperature(40) == 20)
        #expect(c.speedForTemperature(60) == 60)
        #expect(c.speedForTemperature(150) == 60)
    }

    @Test func pointOrderDoesNotMatter() {
        let ordered = curve([(30, 0), (50, 40), (80, 100)])
        let shuffled = curve([(80, 100), (30, 0), (50, 40)])
        let differing = stride(from: 0.0, through: 120.0, by: 0.5).filter {
            ordered.speedForTemperature($0) != shuffled.speedForTemperature($0)
        }
        #expect(differing.isEmpty)
    }

    @Test func anEmptyCurveAsksForNoFan() {
        #expect(FanCurve(points: []).speedForTemperature(70) == 0)
    }

    @Test func aCurveKeepsAtLeastTwoPoints() {
        var c = curve([(40, 20), (60, 60)])
        c.removePoint(at: 0)
        #expect(c.points.count == 2)
    }

    @Test func updatingAPointLeavesTheOthersAlone() {
        var c = curve([(40, 20), (60, 60)])
        let target = c.points[1]
        c.updatePoint(id: target.id, fanSpeed: 80)
        #expect(c.points[0] == curve([(40, 20)]).points[0].withID(c.points[0].id))
        #expect(c.points[1].fanSpeed == 80)
        #expect(c.points[1].temperature == 60)
    }

    /// A curve whose speeds never fall must never ask for a lower speed at a higher
    /// temperature, and never leaves the range its points span.
    @Test(arguments: 0..<200)
    func risingPointsGiveARisingCurve(seed: Int) {
        var rng = SeededGenerator(seed: UInt64(seed))
        var temperature = Double.random(in: 20...40, using: &rng)
        var speed = Double.random(in: 0...30, using: &rng)
        var points: [CurvePoint] = []
        for _ in 0..<Int.random(in: 2...8, using: &rng) {
            points.append(CurvePoint(temperature: temperature, fanSpeed: speed))
            temperature += Double.random(in: 1...15, using: &rng)
            speed = min(100, speed + Double.random(in: 0...20, using: &rng))
        }
        let c = FanCurve(points: points.shuffled(using: &rng))
        let low = points.first!.fanSpeed
        let high = points.last!.fanSpeed

        var previous = -Double.infinity
        var violations: [Double] = []
        for t in stride(from: 0.0, through: 130.0, by: 0.25) {
            let s = c.speedForTemperature(t)
            if s < previous - 1e-9 || s < low - 1e-9 || s > high + 1e-9 { violations.append(t) }
            previous = s
        }
        #expect(violations.isEmpty, "first failing temperatures: \(violations.prefix(5))")
    }
}

private extension CurvePoint {
    func withID(_ id: UUID) -> CurvePoint {
        CurvePoint(id: id, temperature: temperature, fanSpeed: fanSpeed)
    }
}
