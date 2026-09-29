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

    /// Measured on an M3 Pro: 0 mJ idle, about 2.4 W while running Vision models.
    @Test func anUnusedNeuralEngineReadsAsIdle() {
        #expect(SoCPower(ane: 0).neuralEngineIsIdle)
        #expect(SoCPower(ane: 0.0004).neuralEngineIsIdle)
        #expect(!SoCPower(ane: 0.002).neuralEngineIsIdle)
        #expect(!SoCPower(ane: 2.384).neuralEngineIsIdle)
        #expect(!SoCPower().neuralEngineIsIdle, "no reading is unknown, not idle")
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

    /// A minute of load published in one lump must not be divided by the 2s poll.
    /// 105_938 mJ over 60s is 1.77 W, which is what the Neural Engine test measured.
    /// The same lump divided by 2s is the 53 W spike the chart was drawing.
    @Test func aLatePublicationUsesTheCounterTimestamp() throws {
        let ticksPerSecond = 24_000_000.0
        let previous = [
            "CPU Energy": ChannelSample(unit: "mJ", energy: 0, machTicks: 24_000_000),
            "ANE0": ChannelSample(unit: "mJ", energy: 0, machTicks: 24_000_000),
            "GPU Energy": ChannelSample(unit: "nJ", energy: 0, machTicks: 24_000_000),
        ]
        let current = [
            "CPU Energy": ChannelSample(unit: "mJ", energy: 523_864, machTicks: 24_000_000 + 60 * 24_000_000),
            "ANE0": ChannelSample(unit: "mJ", energy: 105_938, machTicks: 24_000_000 + 60 * 24_000_000),
            "GPU Energy": ChannelSample(unit: "nJ", energy: 400_000_000, machTicks: 24_000_000 + 2 * 24_000_000),
        ]
        let power = SoCPower(previous: previous, current: current, wallInterval: 2, ticksPerSecond: ticksPerSecond)

        #expect(abs(try #require(power.cpu) - 523.864 / 60) < 1e-9)
        #expect(power.cpuWindow == 60)
        #expect(abs(try #require(power.ane) - 105.938 / 60) < 1e-9)
        #expect(power.aneWindow == 60)
        #expect(abs(try #require(power.gpu) - 0.2) < 1e-9)
        #expect(power.gpuWindow == 2)
    }

    /// On an M3 Max the ANE mach timestamp stays put while the energy counter
    /// jumps. The wall clock since the previous change is what spreads the lump.
    @Test func aFrozenTimestampUsesTheWallClockSilence() throws {
        let stuck = UInt64(179_632_928_770)
        let previous = ["ANE0": ChannelSample(unit: "mJ", energy: 0, machTicks: stuck)]
        let current = ["ANE0": ChannelSample(unit: "mJ", energy: 105_938, machTicks: stuck)]
        let power = SoCPower(
            previous: previous, current: current,
            wallInterval: 2, ticksPerSecond: 24_000_000,
            silence: ["ANE0": 60]
        )
        #expect(abs(try #require(power.ane) - 105.938 / 60) < 1e-9)
        #expect(power.aneWindow == 60)
    }

    @Test func aSilentCounterDoesNotRewriteHistory() {
        let sample = ["ANE0": ChannelSample(unit: "mJ", energy: 105_938, machTicks: 50)]
        let power = SoCPower(previous: sample, current: sample, wallInterval: 2, ticksPerSecond: 24_000_000)
        #expect(power.ane == 0)
        #expect(power.aneWindow == 0)
        #expect(power.cpu == nil)
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
