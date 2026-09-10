import Foundation

// SMC value encoding and decoding, kept apart from the driver connection in SMCKit
// so it can be tested — and replayed against raw bytes from a diagnostics report —
// without opening the SMC.

struct SMCVal {
    var key: String
    var dataSize: UInt32
    var dataType: String
    var bytes: [UInt8]

    init(key: String = "", dataSize: UInt32 = 0, dataType: String = "", bytes: [UInt8] = []) {
        self.key = key
        self.dataSize = dataSize
        self.dataType = dataType
        self.bytes = bytes
    }
}

// MARK: - Fixed Point Formats

/// Describes an SMC fixed-point type name of the form `spXY` (signed) or `fpXY` (unsigned),
/// where `X` is the number of integer bits and `Y` the number of fractional bits, both hex
/// digits. Signed formats carry an extra sign bit, so `sp78` is 1 + 7 + 8 = 16 bits with a
/// divisor of 2^8, and `fpe2` is 14 + 2 = 16 bits with a divisor of 2^2.
struct FixedPointFormat {
    /// The type used by fan RPM keys on every Mac we have seen; also the write-path fallback.
    static let fpe2 = FixedPointFormat(dataType: "fpe2")!

    let isSigned: Bool
    let integerBits: Int
    let fractionalBits: Int

    var totalBits: Int { integerBits + fractionalBits + (isSigned ? 1 : 0) }
    var byteCount: Int { totalBits / 8 }
    var divisor: Double { Double(UInt64(1) << UInt64(fractionalBits)) }

    /// Largest raw (pre-divisor) value the format can hold.
    private var maxRaw: UInt32 {
        totalBits >= 32 ? UInt32.max : (UInt32(1) << UInt32(totalBits)) - 1
    }

    init?(dataType: String) {
        let dt = dataType.trimmingCharacters(in: .whitespaces).lowercased()
        guard dt.count == 4 else { return nil }

        let prefix = dt.prefix(2)
        switch prefix {
        case "sp": isSigned = true
        case "fp": isSigned = false
        default: return nil
        }

        let digits = Array(dt.dropFirst(2))
        guard let intBits = digits[0].hexDigitValue,
              let fracBits = digits[1].hexDigitValue else { return nil }

        integerBits = intBits
        fractionalBits = fracBits

        // Only whole-byte widths (8/16/24/32 bits) are representable on the wire.
        let bits = intBits + fracBits + (isSigned ? 1 : 0)
        guard bits > 0, bits <= 32, bits % 8 == 0 else { return nil }
    }

    /// Big-endian bytes -> scaled value.
    func decode(_ bytes: [UInt8]) -> Double? {
        guard bytes.count >= byteCount, byteCount > 0 else { return nil }

        var raw: UInt32 = 0
        for i in 0..<byteCount { raw = (raw << 8) | UInt32(bytes[i]) }

        if isSigned {
            let signBit = UInt32(1) << UInt32(totalBits - 1)
            if raw & signBit != 0 {
                // Two's complement: subtract 2^totalBits.
                return Double(Int64(raw) - (Int64(maxRaw) + 1)) / divisor
            }
        }
        return Double(raw) / divisor
    }

    /// Scaled value -> big-endian bytes, saturating at the format's limits. Inverse of `decode`.
    func encode(_ value: Double) -> [UInt8] {
        guard byteCount > 0 else { return [] }

        let signBitValue = Int64(1) << Int64(totalBits - 1)
        let upperBound = isSigned ? Double(signBitValue - 1) : Double(maxRaw)
        let lowerBound = isSigned ? Double(-signBitValue) : 0

        let scaled = (value * divisor).rounded()
        let clamped = Swift.min(Swift.max(scaled, lowerBound), upperBound)

        let raw: UInt32
        if clamped < 0 {
            raw = UInt32(truncatingIfNeeded: Int64(clamped) + Int64(maxRaw) + 1)
        } else {
            raw = UInt32(clamped)
        }

        var out = [UInt8](repeating: 0, count: byteCount)
        for i in 0..<byteCount {
            out[byteCount - 1 - i] = UInt8((raw >> UInt32(8 * i)) & 0xFF)
        }
        return out
    }
}

// MARK: - Value Conversion

enum SMCCodec {

    static func decode(_ val: SMCVal) -> Double? {
        let dt = val.dataType.trimmingCharacters(in: .whitespaces)

        if dt == "flt" && val.bytes.count >= 4 {
            return Double(floatFromBytes(val.bytes))
        }

        // Any spXY / fpXY fixed-point type (sp78, fpe2, sp4b, fp88, ...).
        if let format = FixedPointFormat(dataType: dt), let decoded = format.decode(val.bytes) {
            return decoded
        }

        if dt == "ui8" && val.bytes.count >= 1 { return Double(val.bytes[0]) }

        if dt == "ui16" && val.bytes.count >= 2 {
            let rawValue = (UInt16(val.bytes[0]) << 8) | UInt16(val.bytes[1])
            return Double(rawValue)
        }

        if dt == "ui32" && val.bytes.count >= 4 {
            let rawValue = UInt32(val.bytes[0]) << 24 | UInt32(val.bytes[1]) << 16 |
                           UInt32(val.bytes[2]) << 8 | UInt32(val.bytes[3])
            return Double(rawValue)
        }

        if dt == "si8" && val.bytes.count >= 1 { return Double(Int8(bitPattern: val.bytes[0])) }

        if dt == "si16" && val.bytes.count >= 2 {
            let rawValue = (Int16(val.bytes[0]) << 8) | Int16(val.bytes[1])
            return Double(rawValue)
        }

        // "ioft" is an 8-byte little-endian fixed-point value with 16 fractional
        // bits, NOT a float. Reading its first four bytes as a Float produced a
        // denormal that rounded to zero, so every ioft sensor read as exactly
        // 0.0000 — on an M3 Pro that silently zeroed six GPU temperature sensors
        // (TG0B/TG0C/TG0H/TG0V/TG1B/TG2B) and three thermal ones. Verified
        // against a live key dump: the same bytes yield 26.0-51.9 C here.
        if dt == "ioft" && val.bytes.count >= 8 {
            var raw: UInt64 = 0
            for (index, byte) in val.bytes.prefix(8).enumerated() {
                raw |= UInt64(byte) << (8 * UInt64(index))
            }
            return Double(raw) / 65536.0
        }

        return nil
    }

    /// Little-endian IEEE-754 single, read without relying on the buffer's alignment.
    private static func floatFromBytes(_ bytes: [UInt8]) -> Float {
        let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 |
                   UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        return Float(bitPattern: bits)
    }

    /// Encodes `value` for `dataType`, mirroring `decode`. Returns nil for types with no
    /// known encoding so callers can decide on a fallback.
    static func encode(_ value: Double, dataType: String) -> [UInt8]? {
        let dt = dataType.trimmingCharacters(in: .whitespaces)

        if dt == "flt" {
            return withUnsafeBytes(of: Float(value)) { Array($0) }
        }

        if dt == "ioft" {
            let raw = UInt64((value * 65536.0).rounded())
            return (0..<8).map { UInt8(truncatingIfNeeded: raw >> (8 * UInt64($0))) }
        }

        if let format = FixedPointFormat(dataType: dt) {
            return format.encode(value)
        }

        let rounded = value.rounded()
        switch dt {
        case "ui8":
            return [UInt8(Swift.min(Swift.max(rounded, 0), 255))]
        case "ui16":
            let raw = UInt16(Swift.min(Swift.max(rounded, 0), Double(UInt16.max)))
            return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
        case "ui32":
            let raw = UInt32(Swift.min(Swift.max(rounded, 0), Double(UInt32.max)))
            return [UInt8(raw >> 24 & 0xFF), UInt8(raw >> 16 & 0xFF),
                    UInt8(raw >> 8 & 0xFF), UInt8(raw & 0xFF)]
        case "si8":
            return [UInt8(bitPattern: Int8(Swift.min(Swift.max(rounded, -128), 127)))]
        case "si16":
            let raw = Int16(Swift.min(Swift.max(rounded, Double(Int16.min)), Double(Int16.max)))
            return [UInt8(truncatingIfNeeded: raw >> 8), UInt8(truncatingIfNeeded: raw)]
        default:
            return nil
        }
    }
}
