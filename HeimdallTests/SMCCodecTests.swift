import Foundation
import Testing

/// Every 16-bit fixed-point layout, signed and unsigned.
private let sixteenBitFormats = [
    "sp78", "sp87", "sp96", "spa5", "spb4", "spf0", "sp4b", "sp3c", "sp2d", "sp1e",
    "fp88", "fpe2", "fpc4", "fp6a", "fp4c", "fp2e",
]

@Suite("SMC value codec")
struct SMCCodecTests {

    // MARK: Fixed-point type names

    @Test(arguments: ["sp78", "SP78", "sp78 ", "fpe2", "sp4b", "fp88", "sp1e", "spf0", "fp2e"])
    func acceptsWholeByteFixedPointTypes(dataType: String) {
        #expect(FixedPointFormat(dataType: dataType) != nil)
    }

    @Test(arguments: ["flt ", "ui16", "ioft", "fp77", "sp7", "spzz", "", "hex_"])
    func rejectsAnythingElse(dataType: String) {
        #expect(FixedPointFormat(dataType: dataType) == nil)
    }

    // MARK: Fixed point — known answers

    @Test(arguments: [
        ([0x2A, 0x80], 42.5),
        ([0x64, 0x00], 100.0),
        ([0x00, 0x00], 0.0),
        ([0xFF, 0x80], -0.5),
        ([0x80, 0x00], -128.0),
        ([0x7F, 0xFF], 127.99609375),
    ] as [([UInt8], Double)])
    func sp78(bytes: [UInt8], celsius: Double) throws {
        let format = try #require(FixedPointFormat(dataType: "sp78"))
        #expect(format.decode(bytes) == celsius)
        #expect(format.encode(celsius) == bytes)
    }

    @Test(arguments: [
        ([0x1F, 0x40], 2000.0),
        ([0x13, 0x49], 1234.25),
        ([0x00, 0x00], 0.0),
        ([0xFF, 0xFF], 16383.75),
    ] as [([UInt8], Double)])
    func fpe2(bytes: [UInt8], rpm: Double) {
        #expect(FixedPointFormat.fpe2.decode(bytes) == rpm)
        #expect(FixedPointFormat.fpe2.encode(rpm) == bytes)
    }

    @Test func fixedPointEncodingSaturates() throws {
        #expect(FixedPointFormat.fpe2.encode(1_000_000) == [0xFF, 0xFF])
        #expect(FixedPointFormat.fpe2.encode(-50) == [0x00, 0x00])
        let sp78 = try #require(FixedPointFormat(dataType: "sp78"))
        #expect(sp78.encode(500) == [0x7F, 0xFF])
        #expect(sp78.encode(-500) == [0x80, 0x00])
    }

    /// decode is exact and encode rounds to the same raw value, so every wire
    /// pattern must come back unchanged.
    @Test(arguments: sixteenBitFormats)
    func everyFixedPointBitPatternRoundTrips(dataType: String) throws {
        let format = try #require(FixedPointFormat(dataType: dataType))
        var mismatches: [Int] = []
        for raw in 0...0xFFFF {
            let bytes = [UInt8(raw >> 8), UInt8(raw & 0xFF)]
            guard let value = format.decode(bytes), format.encode(value) == bytes else {
                mismatches.append(raw)
                continue
            }
        }
        #expect(mismatches.isEmpty, "first failing raw values: \(mismatches.prefix(5))")
    }

    @Test func decodingNeedsEnoughBytes() throws {
        let sp78 = try #require(FixedPointFormat(dataType: "sp78"))
        #expect(sp78.decode([0x2A]) == nil)
        #expect(SMCCodec.decode(SMCVal(dataType: "ioft", bytes: [0, 0, 0x20, 0])) == nil)
        #expect(SMCCodec.decode(SMCVal(dataType: "ui32", bytes: [1, 2])) == nil)
        #expect(SMCCodec.decode(SMCVal(dataType: "flt ", bytes: [0, 0])) == nil)
    }

    // MARK: Integers

    @Test(arguments: ["ui8 ", "si8 ", "ui16", "si16"])
    func smallIntegersRoundTripExhaustively(dataType: String) {
        let width = dataType.hasSuffix("16") ? 2 : 1
        var mismatches: [Int] = []
        for raw in 0..<(1 << (8 * width)) {
            let bytes = width == 2 ? [UInt8(raw >> 8), UInt8(raw & 0xFF)] : [UInt8(raw)]
            let back = SMCCodec.decode(SMCVal(dataType: dataType, bytes: bytes))
                .flatMap { SMCCodec.encode($0, dataType: dataType) }
            if back != bytes { mismatches.append(raw) }
        }
        #expect(mismatches.isEmpty, "first failing raw values: \(mismatches.prefix(5))")
    }

    @Test func ui32RoundTrips() {
        var mismatches: [UInt32] = []
        for raw in Array(stride(from: UInt32(0), to: UInt32.max, by: 65_521)) + [UInt32.max] {
            let bytes = [UInt8(raw >> 24), UInt8(raw >> 16 & 0xFF), UInt8(raw >> 8 & 0xFF), UInt8(raw & 0xFF)]
            let back = SMCCodec.decode(SMCVal(dataType: "ui32", bytes: bytes))
                .flatMap { SMCCodec.encode($0, dataType: "ui32") }
            if back != bytes { mismatches.append(raw) }
        }
        #expect(mismatches.isEmpty, "first failing raw values: \(mismatches.prefix(5))")
    }

    @Test func integerEncodingClampsToTheTypeRange() {
        #expect(SMCCodec.encode(300, dataType: "ui8 ") == [0xFF])
        #expect(SMCCodec.encode(-3, dataType: "ui8 ") == [0x00])
        #expect(SMCCodec.encode(-200, dataType: "si8 ") == [0x80])
        #expect(SMCCodec.encode(40_000, dataType: "si16") == [0x7F, 0xFF])
        #expect(SMCCodec.encode(-1, dataType: "ui32") == [0, 0, 0, 0])
    }

    // MARK: ioft

    /// 8-byte little-endian with 16 fractional bits. It was once read as a Float,
    /// which zeroed every ioft sensor on an M3 Pro.
    @Test func ioftIsLittleEndianFixedPoint() {
        let tg0b = SMCVal(dataType: "ioft", bytes: [0x33, 0xB3, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00])
        #expect(SMCCodec.decode(tg0b) == Double(0x20B333) / 65536)
        #expect(SMCCodec.encode(32.7, dataType: "ioft") == tg0b.bytes)
    }

    @Test func ioftRoundTripsWithinItsResolution() {
        var worst = 0.0
        for value in stride(from: 0.0, through: 150.0, by: 0.013) {
            guard let bytes = SMCCodec.encode(value, dataType: "ioft"),
                  let back = SMCCodec.decode(SMCVal(dataType: "ioft", bytes: bytes)) else {
                Issue.record("ioft \(value) did not round-trip")
                return
            }
            worst = max(worst, abs(back - value))
        }
        #expect(worst <= 0.5 / 65536 + 1e-12)
    }

    // MARK: flt

    @Test func fltIsLittleEndianIEEE754() {
        let tenAmps = SMCVal(dataType: "flt ", bytes: [0x00, 0x00, 0x20, 0x41])
        #expect(SMCCodec.decode(tenAmps) == 10)
        #expect(SMCCodec.encode(10, dataType: "flt ") == tenAmps.bytes)
    }

    @Test func fltRoundTripsAtSinglePrecision() {
        var rng = SeededGenerator(seed: 0xF17)
        var mismatches: [Double] = []
        for _ in 0..<5_000 {
            let value = Double.random(in: -10_000...10_000, using: &rng)
            let back = SMCCodec.encode(value, dataType: "flt ")
                .flatMap { SMCCodec.decode(SMCVal(dataType: "flt ", bytes: $0)) }
            if back != Double(Float(value)) { mismatches.append(value) }
        }
        #expect(mismatches.isEmpty, "first failing values: \(mismatches.prefix(5))")
    }

    // MARK: Unsupported

    @Test(arguments: ["hex_", "flag", "ch8*", "si32", "ui64", "{jst"])
    func typesWithoutAKnownEncodingAreNil(dataType: String) {
        #expect(SMCCodec.decode(SMCVal(dataType: dataType, bytes: [UInt8](repeating: 1, count: 8))) == nil)
        #expect(SMCCodec.encode(1, dataType: dataType) == nil)
    }
}
