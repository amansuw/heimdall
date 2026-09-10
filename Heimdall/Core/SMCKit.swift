import Foundation
import IOKit

// MARK: - SMC Data Types

struct SMCKeyData {
    struct Vers {
        var major: CUnsignedChar = 0
        var minor: CUnsignedChar = 0
        var build: CUnsignedChar = 0
        var reserved: CUnsignedChar = 0
        var release: CUnsignedShort = 0
    }

    struct PLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct KeyInfo {
        var dataSize: IOByteCount32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers: Vers = Vers()
    var pLimitData: PLimitData = PLimitData()
    var keyInfo: KeyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
               (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

// MARK: - SMC Constants

public enum FanMode: Int, Codable {
    case automatic = 0
    case forced = 1
}

private let kSMCUserClientOpen: UInt32 = 0
private let kSMCUserClientClose: UInt32 = 1
private let kSMCHandleYPCEvent: UInt32 = 2

private let kSMCCmdReadKey: UInt8 = 5
private let kSMCCmdWriteKey: UInt8 = 6
private let kSMCCmdGetKeyFromIndex: UInt8 = 8
private let kSMCCmdGetKeyInfo: UInt8 = 9

// MARK: - SMCKit

/// Safe to share across queues: every use of the driver connection and the caches
/// goes through `lock`.
final class SMCKit: @unchecked Sendable {
    static let shared = SMCKit()

    /// Serialises every use of the driver connection and the caches below.
    ///
    /// This is a process-wide singleton reached from at least three queues — the
    /// monitor's fast queue (sensor sampling), the fan helper queue, and the main
    /// thread (fan discovery, quit). `keyInfoCache` is a Dictionary, so concurrent
    /// mutation is not merely a stale read: it can corrupt the hash table and
    /// crash. Recursive because the public methods call one another.
    private let lock = NSRecursiveLock()

    private var connection: io_connect_t = 0
    private var _isOpen = false
    var isOpen: Bool { lock.withLock { _isOpen } }

    private var keyInfoCache: [UInt32: SMCKeyData.KeyInfo] = [:]

    private init() {
        open()
    }

    deinit {
        close()
    }

    // MARK: - Connection

    @discardableResult
    func open() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !_isOpen else { return true }

        let matchingDictionary: CFMutableDictionary = IOServiceMatching("AppleSMC")
        var iterator: io_iterator_t = 0

        let matchResult = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDictionary, &iterator)
        if matchResult != kIOReturnSuccess { return false }

        let device = IOIteratorNext(iterator)
        IOObjectRelease(iterator)
        guard device != 0 else { return false }

        let result = IOServiceOpen(device, mach_task_self_, 0, &connection)
        IOObjectRelease(device)

        if result == kIOReturnSuccess {
            _isOpen = true
            return true
        }
        return false
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }

        guard _isOpen else { return }
        IOServiceClose(connection)
        _isOpen = false
    }

    // MARK: - Key Operations

    private func stringToUInt32(_ str: String) -> UInt32 {
        var result: UInt32 = 0
        let utf8 = Array(str.utf8)
        for i in 0..<min(4, utf8.count) {
            result = (result << 8) | UInt32(utf8[i])
        }
        for _ in utf8.count..<4 {
            result = (result << 8) | UInt32(0x20)
        }
        return result
    }

    private func uint32ToString(_ value: UInt32) -> String {
        var str = ""
        var v = value
        for _ in 0..<4 {
            let byte = UInt8((v >> 24) & 0xFF)
            if byte >= 0x20 && byte < 0x7F {
                str.append(Character(UnicodeScalar(byte)))
            } else {
                str.append("?")
            }
            v <<= 8
        }
        return str
    }

    private func bytesFromTuple(_ tuple: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                           UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                           UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                           UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8),
                                 count: Int) -> [UInt8] {
        var result = [UInt8]()
        result.reserveCapacity(count)
        var copy = tuple
        withUnsafePointer(to: &copy) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: 32) { bytes in
                for i in 0..<min(count, 32) {
                    result.append(bytes[i])
                }
            }
        }
        return result
    }

    private var kernelSelector: UInt32 = kSMCHandleYPCEvent
    private var selectorProbed = false

    private func probeSelector() {
        guard !selectorProbed else { return }
        selectorProbed = true

        let candidates: [UInt32] = [2, 0, 1, 5]
        let testKeys = ["#KEY", "TC0P", "Tp09"]

        for sel in candidates {
            for testKey in testKeys {
                var testInput = SMCKeyData()
                testInput.key = stringToUInt32(testKey)
                testInput.data8 = kSMCCmdGetKeyInfo

                var testOutput = SMCKeyData()
                let inputSize = MemoryLayout<SMCKeyData>.stride
                var outputSize = MemoryLayout<SMCKeyData>.stride

                let result = IOConnectCallStructMethod(
                    connection, sel, &testInput, inputSize, &testOutput, &outputSize
                )

                if result == kIOReturnSuccess && testOutput.keyInfo.dataSize > 0 {
                    kernelSelector = sel
                    return
                }
            }
        }
    }

    private func callSMC(command: UInt8, inputData: inout SMCKeyData) -> SMCKeyData? {
        guard _isOpen else { return nil }

        if !selectorProbed { probeSelector() }

        inputData.data8 = command

        var outputData = SMCKeyData()
        let inputSize = MemoryLayout<SMCKeyData>.stride
        var outputSize = MemoryLayout<SMCKeyData>.stride

        let result = IOConnectCallStructMethod(
            connection, kernelSelector, &inputData, inputSize, &outputData, &outputSize
        )

        guard result == kIOReturnSuccess else { return nil }
        return outputData
    }

    func readKey(_ key: String) -> SMCVal? {
        lock.lock()
        defer { lock.unlock() }

        let keyInt = stringToUInt32(key)

        let info: SMCKeyData.KeyInfo
        if let cached = keyInfoCache[keyInt] {
            info = cached
        } else {
            var inputData = SMCKeyData()
            inputData.key = keyInt
            guard let keyInfoResult = callSMC(command: kSMCCmdGetKeyInfo, inputData: &inputData) else { return nil }
            guard keyInfoResult.keyInfo.dataSize > 0 else { return nil }
            info = keyInfoResult.keyInfo
            keyInfoCache[keyInt] = info
        }

        var readData = SMCKeyData()
        readData.key = keyInt
        readData.keyInfo.dataSize = info.dataSize

        guard let readResult = callSMC(command: kSMCCmdReadKey, inputData: &readData) else { return nil }

        let dataType = uint32ToString(info.dataType)
        let bytes = bytesFromTuple(readResult.bytes, count: Int(info.dataSize))

        return SMCVal(key: key, dataSize: info.dataSize, dataType: dataType, bytes: bytes)
    }

    func writeKey(_ key: String, bytes: [UInt8]) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        var inputData = SMCKeyData()
        inputData.key = stringToUInt32(key)

        guard let keyInfoResult = callSMC(command: kSMCCmdGetKeyInfo, inputData: &inputData) else { return false }

        var writeData = SMCKeyData()
        writeData.key = stringToUInt32(key)
        writeData.keyInfo.dataSize = keyInfoResult.keyInfo.dataSize

        var tupleBytes = writeData.bytes
        withUnsafeMutablePointer(to: &tupleBytes) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: 32) { dest in
                for (i, byte) in bytes.enumerated() {
                    if i < 32 { dest[i] = byte }
                }
            }
        }
        writeData.bytes = tupleBytes

        return callSMC(command: kSMCCmdWriteKey, inputData: &writeData) != nil
    }

    // MARK: - Value Conversion

    // The conversions live in SMCCodec, where they can be tested without a driver
    // connection.

    func decodeValue(_ val: SMCVal) -> Double? {
        SMCCodec.decode(val)
    }

    func encodeValue(_ value: Double, dataType: String) -> [UInt8]? {
        SMCCodec.encode(value, dataType: dataType)
    }

    func readFloat(_ key: String) -> Double? {
        guard let val = readKey(key) else { return nil }
        return decodeValue(val)
    }

    // MARK: - Fan Operations

    func getNumberOfFans() -> Int {
        guard let val = readKey("FNum") else { return 0 }
        if let decoded = decodeValue(val) { return Int(decoded) }
        if val.bytes.count >= 1 { return Int(val.bytes[0]) }
        return 0
    }

    func getFanCurrentSpeed(fanIndex: Int) -> Double? {
        readFloat("F\(fanIndex)Ac")
    }

    func getFanMinSpeed(fanIndex: Int) -> Double? {
        readFloat("F\(fanIndex)Mn")
    }

    func getFanMaxSpeed(fanIndex: Int) -> Double? {
        readFloat("F\(fanIndex)Mx")
    }

    func getFanTargetSpeed(fanIndex: Int) -> Double? {
        readFloat("F\(fanIndex)Tg")
    }

    func setFanMinSpeed(fanIndex: Int, speed: Double) -> Bool {
        guard let val = readKey("F\(fanIndex)Mn") else { return false }
        let bytes = encodeSpeed(speed, dataType: val.dataType)
        return writeKey("F\(fanIndex)Mn", bytes: bytes)
    }

    func setFanTargetSpeed(fanIndex: Int, speed: Double) -> Bool {
        guard let val = readKey("F\(fanIndex)Tg") else { return false }
        let bytes = encodeSpeed(speed, dataType: val.dataType)
        return writeKey("F\(fanIndex)Tg", bytes: bytes)
    }

    /// Encodes an RPM value for a fan key using that key's actual data type.
    /// Unknown types fall back to fpe2, which is what the SMC uses for fan keys on every
    /// Mac we have seen.
    func encodeSpeed(_ speed: Double, dataType: String) -> [UInt8] {
        if let bytes = encodeValue(speed, dataType: dataType) { return bytes }
        return FixedPointFormat.fpe2.encode(speed)
    }

    func setFanMode(fanIndex: Int, mode: FanMode) -> Bool {
        let modeKey = "F\(fanIndex)Md"
        if let _ = readKey(modeKey) {
            return writeKey(modeKey, bytes: [UInt8(mode.rawValue)])
        }

        let fsKey = "FS! "
        guard let val = readKey(fsKey) else { return false }

        let currentMode = Int(decodeValue(val) ?? 0)
        var newMode: Int
        if mode == .forced {
            newMode = currentMode | (1 << fanIndex)
        } else {
            newMode = currentMode & ~(1 << fanIndex)
        }

        if val.dataSize == 2 {
            return writeKey(fsKey, bytes: [0x00, UInt8(newMode)])
        } else {
            return writeKey(fsKey, bytes: [UInt8(newMode)])
        }
    }

    func testWriteAccess() -> Bool {
        if let val = readKey("FS! ") {
            return writeKey("FS! ", bytes: val.bytes.prefix(Int(val.dataSize)).map { $0 })
        }
        if let val = readKey("F0Md") {
            return writeKey("F0Md", bytes: val.bytes.prefix(Int(val.dataSize)).map { $0 })
        }
        return false
    }

    func resetAllFansToAutomatic() {
        let numFans = getNumberOfFans()
        for i in 0..<numFans {
            _ = setFanMode(fanIndex: i, mode: .automatic)
        }
        if let val = readKey("FS! ") {
            let zeros = [UInt8](repeating: 0, count: Int(val.dataSize))
            _ = writeKey("FS! ", bytes: zeros)
        }
    }

    // MARK: - Key Enumeration

    func getKeyCount() -> Int {
        guard let val = readKey("#KEY") else { return 0 }
        if val.bytes.count >= 4 {
            return Int(UInt32(val.bytes[0]) << 24 | UInt32(val.bytes[1]) << 16 |
                       UInt32(val.bytes[2]) << 8 | UInt32(val.bytes[3]))
        }
        return 0
    }

    func getKeyAtIndex(_ index: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }

        var inputData = SMCKeyData()
        inputData.data32 = UInt32(index)
        guard let result = callSMC(command: kSMCCmdGetKeyFromIndex, inputData: &inputData) else { return nil }
        return uint32ToString(result.key)
    }

    func getAllKeys() -> [String] {
        let count = getKeyCount()
        var keys: [String] = []
        keys.reserveCapacity(count)
        for i in 0..<count {
            if let key = getKeyAtIndex(i) {
                keys.append(key)
            }
        }
        return keys
    }
}
