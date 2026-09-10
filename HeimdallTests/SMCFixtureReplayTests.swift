import Foundation
import Testing

/// Rows from the SMC table of a diagnostics report (`Heimdall --dump-diagnostics`)
/// taken on an M3 Pro MacBook Pro: key, type, size, raw bytes, decoded value.
///
/// This pins behaviour; it does not prove correctness. The last column is what the
/// decoder produced when the report was taken, so any change in how real hardware
/// bytes decode has to update this fixture deliberately, in the same commit.
/// Reports attached to hardware issues can be added as further fixtures.
///
/// Integer byte order, which these rows make visible. On this M3 Pro, among integer
/// keys whose value depends on byte order, the little-endian reading is the
/// plausible one for most of them (ui16 83 of 97, ui32 76 of 86, si16 16 of 17):
/// ACPO and ACPW decode to billions big-endian but 33000 / 67800 little-endian,
/// while #KEY only makes sense big-endian. SMCCodec stays big-endian, which is right
/// for the Intel keys it writes (FS!). No integer key Heimdall shows or writes on
/// Apple Silicon is affected: fan keys are ui8/flt, and the one integer sensor
/// candidate, VBUS, decodes out of the voltage sanity range and is never shown.
/// Decide byte order per key, with evidence, before displaying an integer sensor.
let m3ProSMCRows = """
#KEY ui32 4     00 00 08 F7 2295.0000
AC-B si8 1     FF -1.0000
AC-C flag 1     00 -
AC-I ui16 2     00 49 73.0000
AC-M hex_ 2     01 01 -
AC-N ui8 1     04 4.0000
ACCF ui8 1     1E 30.0000
ACDI ui16 2     3E 0D 15885.0000
ACPO ui32 4     E8 80 00 00 3900702720.0000
ACPW ui32 4     D8 08 01 00 3624403200.0000
AOPb ui64 8     00 E1 E6 6D 03 00 00 00 -
AP1F si16 2     B8 06 -18426.0000
AP1P ui16 2     94 06 37894.0000
AP1V si16 2     69 14 26900.0000
B0AP si32 4     00 00 00 00 -
BMDA ch8* 32    00 00 00 00 0B 00 01 00 62 1B 00 00 04 32 37 31 34 03 30 30 35 03 41 54 4C 00 00 00 00 00 00 00 -
BNCB si8 1     03 3.0000
F0Ac flt 4     00 00 00 00 0.0000
F0Mn flt 4     00 D0 10 45 2317.0000
F0Mx flt 4     00 80 D4 45 6800.0000
F0Tg flt 4     00 00 00 00 0.0000
F1Mn flt 4     00 D0 10 45 2317.0000
F1Mx flt 4     00 80 D4 45 6800.0000
ID0R flt 4     B6 0B 3C 3F 0.7346
PSTR flt 4     99 AA 65 41 14.3541
TB0T flt 4     CC CC 02 42 32.7000
TB2T flt 4     64 66 02 42 32.6000
TCDX flt 4     00 18 43 42 48.7734
TCHP flt 4     68 21 21 42 40.2826
TCMz flt 4     00 68 89 42 68.7031
VD0R flt 4     5B 47 A3 41 20.4098
TG0B ioft 8     33 B3 20 00 00 00 00 00 32.7000
TG0C ioft 8     00 00 20 00 00 00 00 00 32.0000
TG2B ioft 8     99 99 20 00 00 00 00 00 32.6000
TR0Z ioft 8     9A D9 33 00 00 00 00 00 51.8500
TR1d ioft 8     DF 94 28 00 00 00 00 00 40.5815
TR2d ioft 8     4E AF 2A 00 00 00 00 00 42.6848
aDCR ioft 8     00 00 00 00 00 00 00 00 0.0000
"""

struct SMCFixtureRow: CustomTestStringConvertible, Sendable {
    let key: String
    let dataType: String
    let bytes: [UInt8]
    /// nil where the report printed "-": the type has no decoding.
    let decoded: Double?

    var testDescription: String { "\(key) (\(dataType))" }

    var value: SMCVal {
        SMCVal(key: key, dataSize: UInt32(bytes.count), dataType: dataType, bytes: bytes)
    }

    init?(row: Substring) {
        let fields = row.split(separator: " ").map(String.init)
        guard fields.count >= 5, let size = Int(fields[2]), fields.count == 3 + size + 1 else { return nil }
        let bytes = fields[3..<(3 + size)].compactMap { UInt8($0, radix: 16) }
        guard bytes.count == size else { return nil }
        key = fields[0]
        dataType = fields[1]
        self.bytes = bytes
        decoded = fields[fields.count - 1] == "-" ? nil : Double(fields[fields.count - 1])
    }
}

let m3ProSMCFixture = m3ProSMCRows.split(separator: "\n").compactMap(SMCFixtureRow.init(row:))

@Suite("SMC fixture replay")
struct SMCFixtureReplayTests {

    @Test func everyRowParses() {
        #expect(m3ProSMCFixture.count == m3ProSMCRows.split(separator: "\n").count)
    }

    @Test(arguments: m3ProSMCFixture)
    func decodesAsRecorded(_ row: SMCFixtureRow) throws {
        let decoded = SMCCodec.decode(row.value)
        guard let expected = row.decoded else {
            #expect(decoded == nil)
            return
        }
        let actual = try #require(decoded)
        // The report prints four decimals.
        #expect(abs(actual - expected) <= 0.00005 + 1e-9)
    }

    /// Fan limits and targets are written back to the SMC, so what was read must
    /// encode to the same bytes.
    @Test(arguments: m3ProSMCFixture.filter { $0.key.hasPrefix("F") })
    func fanKeysEncodeBackToTheirBytes(_ row: SMCFixtureRow) throws {
        let decoded = try #require(SMCCodec.decode(row.value))
        #expect(SMCCodec.encode(decoded, dataType: row.dataType) == row.bytes)
    }
}
