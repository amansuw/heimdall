import Foundation
import Testing

@Suite("Temperature unit")
struct TemperatureUnitTests {

    @Test func knownConversions() {
        #expect(TemperatureUnit.fahrenheit.convert(100) == 212)
        #expect(TemperatureUnit.fahrenheit.convert(0) == 32)
        #expect(TemperatureUnit.fahrenheit.convert(-40) == -40)
        #expect(TemperatureUnit.celsius.convert(37.5) == 37.5)
    }

    /// Curve points are stored in Celsius and typed in the display unit, so a value
    /// shown and typed back must land where it started.
    @Test(arguments: TemperatureUnit.allCases)
    func toCelsiusInvertsConvert(unit: TemperatureUnit) {
        let drift = stride(from: -50.0, through: 150.0, by: 0.25).map {
            abs(unit.toCelsius(unit.convert($0)) - $0)
        }.max() ?? 0
        #expect(drift < 1e-9)
    }
}
