import Foundation
import Testing

@Suite("SoC power")
struct PowerReaderTests {

    @Test(arguments: [
        ("J", 3, 3.0),
        ("mJ", 2608, 2.608),
        ("uJ", 5_000_000, 5.0),
        ("µJ", 250_000, 0.25),
        ("nJ", 191_895_138, 0.191895138),
    ] as [(String, Int64, Double)])
    func energyUnitsConvertToJoules(unit: String, value: Int64, joules: Double) throws {
        let converted = try #require(EnergyReading(channel: "CPU Energy", unit: unit, value: value).joules)
        #expect(abs(converted - joules) < 1e-12)
    }

    @Test func unknownUnitsAreNotGuessed() {
        #expect(EnergyReading(channel: "CPU Energy", unit: "mWh", value: 5).joules == nil)
    }

    /// Channel values from a real one-second sample on an M3 Pro, where GPU
    /// Energy arrives in nanojoules and the rest in millijoules.
    @Test func aRealSampleBecomesWatts() throws {
        let readings = [
            EnergyReading(channel: "ECPU", unit: "mJ", value: 624),
            EnergyReading(channel: "PCPU", unit: "mJ", value: 1983),
            EnergyReading(channel: "CPU Energy", unit: "mJ", value: 2608),
            EnergyReading(channel: "GPU", unit: "mJ", value: 193),
            EnergyReading(channel: "GPU Energy", unit: "nJ", value: 191_895_138),
            EnergyReading(channel: "ANE", unit: "mJ", value: 0),
            EnergyReading(channel: "DRAM", unit: "mJ", value: 727),
        ]
        let power = SoCPower(readings: readings, interval: 2)

        #expect(abs(try #require(power.cpu) - 1.304) < 1e-9)
        #expect(abs(try #require(power.gpu) - 0.095947569) < 1e-9)
        #expect(power.ane == 0)
        #expect(abs(try #require(power.memory) - 0.3635) < 1e-9)
        #expect(abs(try #require(power.combined) - (1.304 + 0.095947569)) < 1e-9)
    }

    @Test func broaderChannelNamesAreUsedWhenTheUsualOnesAreMissing() {
        let readings = [
            EnergyReading(channel: "ECPU", unit: "mJ", value: 500),
            EnergyReading(channel: "PCPU", unit: "mJ", value: 1500),
            EnergyReading(channel: "GPU", unit: "mJ", value: 400),
            EnergyReading(channel: "ANE0", unit: "mJ", value: 100),
            EnergyReading(channel: "ANE0 SRAM", unit: "mJ", value: 900),
        ]
        let power = SoCPower(readings: readings, interval: 1)
        #expect(power.cpu == 2.0)
        #expect(power.gpu == 0.4)
        #expect(power.ane == 0.1)
        #expect(power.memory == nil)
    }

    @Test func missingRailsStayMissing() {
        let power = SoCPower(readings: [EnergyReading(channel: "CPU Energy", unit: "mJ", value: 1000)], interval: 1)
        #expect(power.gpu == nil)
        #expect(power.ane == nil)
        #expect(power.combined == 1.0)
    }

    @Test func aZeroIntervalGivesNoPower() {
        let power = SoCPower(readings: [EnergyReading(channel: "CPU Energy", unit: "mJ", value: 1000)], interval: 0)
        #expect(power == SoCPower())
        #expect(power.combined == nil)
    }

    @Test func aWrappedCounterIsNotNegativePower() {
        let power = SoCPower(readings: [EnergyReading(channel: "CPU Energy", unit: "mJ", value: -5)], interval: 1)
        #expect(power.cpu == 0)
    }

    @Test func aRailInAnUnknownUnitIsDroppedNotMisread() {
        let power = SoCPower(readings: [EnergyReading(channel: "GPU Energy", unit: "mWh", value: 5)], interval: 1)
        #expect(power.gpu == nil)
    }

    /// The live reader against this machine. CI runners and virtual machines may
    /// expose no Energy Model channels, so this only insists that whatever comes
    /// back is physically sane.
    @Test func theLiveReaderReturnsSaneWattsOrNothing() {
        let reader = PowerReader()
        #expect(reader.read() == nil, "the first read only primes the baseline")
        Thread.sleep(forTimeInterval: 0.5)
        guard let power = reader.read() else { return }
        for watts in [power.cpu, power.gpu, power.ane, power.memory].compactMap({ $0 }) {
            #expect(watts.isFinite && watts >= 0 && watts < 500)
        }
    }
}
