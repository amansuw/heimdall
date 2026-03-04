import Foundation

class FanController {
    weak var fanState: FanState?
    weak var sensorState: SensorState?

    private let smc = SMCKit.shared
    private let helperQueue = DispatchQueue(label: "com.heimdall.fan", qos: .userInitiated)

    private var helperRunning = false
    private var cmdFd: Int32 = -1
    private var rspFd: Int32 = -1
    private var rspBuffer = Data()
    private var forceTestModeActive = false

    private var curveFansForced = false
    private var lastCurveAboveZero: Date = .distantPast
    private let curveModeTransitionCooldown: TimeInterval = 30

    private var pendingFanSpeeds: [(Int, Double)]?

    // MARK: - Init

    func discoverFans() {
        let numFans = smc.getNumberOfFans()
        var discovered: [FanInfo] = []

        for i in 0..<numFans {
            let current = smc.getFanCurrentSpeed(fanIndex: i)
            let min = smc.getFanMinSpeed(fanIndex: i)
            let max = smc.getFanMaxSpeed(fanIndex: i)
            let target = smc.getFanTargetSpeed(fanIndex: i)

            discovered.append(FanInfo(
                id: i, index: i,
                currentSpeed: current ?? 0, minSpeed: min ?? 0,
                maxSpeed: max ?? 6500, targetSpeed: target ?? (current ?? 0),
                isManual: false
            ))
        }

        DispatchQueue.main.async { [weak self] in
            self?.fanState?.fans = discovered
            let directWrite = self?.smc.testWriteAccess() ?? false
            self?.fanState?.hasWriteAccess = (self?.fanState?.hasWriteAccess ?? false) || directWrite
        }
    }

    func restoreWriteAccessSilently() {
        helperQueue.async { [weak self] in
            guard let self else { return }

            let connected = self.tryReconnectToDaemon(waitUpTo: 5)
            let directWrite = self.smc.testWriteAccess()

            DispatchQueue.main.async {
                self.fanState?.hasWriteAccess = connected || directWrite || (self.fanState?.hasWriteAccess ?? false)
            }
        }
    }

    // MARK: - Daemon Connection

    func requestAdminAccess() {
        guard !(fanState?.isRequestingAccess ?? true) else { return }
        DispatchQueue.main.async { self.fanState?.isRequestingAccess = true }

        helperQueue.async { [weak self] in
            guard let self else { return }

            self.closePersistentFDs()

            if SMCDaemon.isDaemonRunning() {
                if self.connectToFIFOs(cmd: SMCDaemon.cmdPath, rsp: SMCDaemon.rspPath) {
                    self.onDaemonConnected()
                    return
                }
            }

            if SMCDaemon.isDaemonInstalled() {
                let deadline = Date().addingTimeInterval(10)
                while Date() < deadline {
                    if SMCDaemon.isDaemonRunning() {
                        if self.connectToFIFOs(cmd: SMCDaemon.cmdPath, rsp: SMCDaemon.rspPath) {
                            self.onDaemonConnected()
                            return
                        }
                    }
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }

            let installed = SMCDaemon.installDaemon()
            guard installed else {
                DispatchQueue.main.async { self.fanState?.isRequestingAccess = false }
                return
            }

            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                if SMCDaemon.isDaemonRunning() {
                    if self.connectToFIFOs(cmd: SMCDaemon.cmdPath, rsp: SMCDaemon.rspPath) {
                        self.onDaemonConnected()
                        return
                    }
                }
                Thread.sleep(forTimeInterval: 0.5)
            }

            DispatchQueue.main.async { self.fanState?.isRequestingAccess = false }
        }
    }

    private func connectToFIFOs(cmd cmdPath: String, rsp rspPath: String) -> Bool {
        cmdFd = Darwin.open(cmdPath, O_WRONLY)
        guard cmdFd >= 0 else { return false }
        rspFd = Darwin.open(rspPath, O_RDONLY)
        guard rspFd >= 0 else { Darwin.close(cmdFd); cmdFd = -1; return false }
        helperRunning = true
        rspBuffer = Data()
        return true
    }

    private func onDaemonConnected() {
        let numFans = smc.getNumberOfFans()
        var allOk = true
        for i in 0..<numFans {
            if !setFanModeWrite(fanIndex: i, mode: .automatic) { allOk = false }
        }

        DispatchQueue.main.async { [weak self] in
            self?.fanState?.hasWriteAccess = allOk
            self?.fanState?.isRequestingAccess = false
        }
    }

    private func closePersistentFDs() {
        if cmdFd >= 0 { Darwin.close(cmdFd); cmdFd = -1 }
        if rspFd >= 0 { Darwin.close(rspFd); rspFd = -1 }
    }

    private func tryReconnectToDaemon(waitUpTo timeout: TimeInterval) -> Bool {
        if helperRunning && cmdFd >= 0 && rspFd >= 0 { return true }

        closePersistentFDs()
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if SMCDaemon.isDaemonRunning() {
                if connectToFIFOs(cmd: SMCDaemon.cmdPath, rsp: SMCDaemon.rspPath) {
                    return true
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }

        return false
    }

    func shutdown() {
        if forceTestModeActive && helperRunning {
            _ = smcWrite(key: "Ftst", bytes: [0x00])
            forceTestModeActive = false
        }
        helperRunning = false
        closePersistentFDs()
    }

    // MARK: - FIFO Communication

    private func sendCommand(_ command: String, timeout: TimeInterval = 5) -> String? {
        guard helperRunning, cmdFd >= 0, rspFd >= 0 else { return nil }

        let cmdBytes = Array((command + "\n").utf8)
        let written = cmdBytes.withUnsafeBufferPointer { ptr -> Int in
            Darwin.write(cmdFd, ptr.baseAddress!, ptr.count)
        }
        guard written > 0 else {
            helperRunning = false
            DispatchQueue.main.async { self.fanState?.hasWriteAccess = false }
            return nil
        }

        var buf = [UInt8](repeating: 0, count: 256)
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let nlRange = rspBuffer.range(of: Data([0x0A])) {
                let lineData = rspBuffer[rspBuffer.startIndex..<nlRange.lowerBound]
                rspBuffer.removeSubrange(rspBuffer.startIndex...nlRange.lowerBound)
                return String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let n = Darwin.read(rspFd, &buf, buf.count)
            if n <= 0 {
                helperRunning = false
                DispatchQueue.main.async { self.fanState?.hasWriteAccess = false }
                return nil
            }
            rspBuffer.append(contentsOf: buf[0..<n])
        }
        return nil
    }

    private func privilegedWrite(key: String, bytes: [UInt8]) -> Bool {
        let hexStr = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        return sendCommand("WRITE \(key) \(hexStr)")?.hasPrefix("OK") ?? false
    }

    private func privilegedReadDouble(key: String) -> Double? {
        guard let response = sendCommand("READ \(key)") else { return nil }
        if response.hasPrefix("VAL ") {
            return Double(response.dropFirst(4).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private func smcWrite(key: String, bytes: [UInt8]) -> Bool {
        if helperRunning { return privilegedWrite(key: key, bytes: bytes) }
        return smc.writeKey(key, bytes: bytes)
    }

    // MARK: - thermalmonitord Unlock

    private func ensureForceTestMode() {
        guard !forceTestModeActive else { return }
        DispatchQueue.main.async { self.fanState?.isYielding = true }

        let r = smcWrite(key: "Ftst", bytes: [0x01])
        guard r else {
            DispatchQueue.main.async { self.fanState?.isYielding = false }
            return
        }

        for _ in 1...12 {
            Thread.sleep(forTimeInterval: 0.5)
            if let mdVal = privilegedReadDouble(key: "F0Md"), mdVal != 3.0 {
                Thread.sleep(forTimeInterval: 1.0)
                _ = smcWrite(key: "Ftst", bytes: [0x01])
                forceTestModeActive = true
                DispatchQueue.main.async { self.fanState?.isYielding = false }
                return
            }
            _ = smcWrite(key: "F0Md", bytes: [0x01])
        }

        forceTestModeActive = true
        DispatchQueue.main.async { self.fanState?.isYielding = false }
    }

    private func disableForceTestMode() {
        guard forceTestModeActive else { return }
        _ = smcWrite(key: "Ftst", bytes: [0x00])
        forceTestModeActive = false
    }

    // MARK: - Fan Mode/Speed Writes

    private func setFanModeWrite(fanIndex: Int, mode: FanMode) -> Bool {
        if mode == .forced { ensureForceTestMode() }

        var success = false
        let modeKey = "F\(fanIndex)Md"
        if let val = smc.readKey(modeKey) {
            var modeBytes = [UInt8](repeating: 0, count: Int(val.dataSize))
            modeBytes[0] = UInt8(mode.rawValue)
            if smcWrite(key: modeKey, bytes: modeBytes) { success = true }
        }

        if let val = smc.readKey("FS! ") {
            let current = Int(smc.decodeValue(val) ?? 0)
            let newMode = mode == .forced ? (current | (1 << fanIndex)) : (current & ~(1 << fanIndex))
            let fsBytes: [UInt8] = val.dataSize == 2 ? [UInt8(newMode >> 8), UInt8(newMode & 0xFF)] : [UInt8(newMode)]
            if smcWrite(key: "FS! ", bytes: fsBytes) { success = true }
        }

        return success
    }

    private func setFanTargetWrite(fanIndex: Int, speed: Double) -> Bool {
        var success = false

        func encodeSpeed(_ key: String) -> [UInt8]? {
            guard let val = smc.readKey(key) else { return nil }
            let dt = val.dataType.trimmingCharacters(in: .whitespaces)
            if dt == "flt" {
                let f = Float(speed)
                return withUnsafeBytes(of: f) { Array($0) }
            } else {
                let s = Int(speed)
                return [UInt8(s >> 6), UInt8((s << 2) ^ ((s >> 6) << 8))]
            }
        }

        if let bytes = encodeSpeed("F\(fanIndex)Tg") {
            if smcWrite(key: "F\(fanIndex)Tg", bytes: bytes) { success = true }
        }
        if let bytes = encodeSpeed("F\(fanIndex)Mn") {
            if smcWrite(key: "F\(fanIndex)Mn", bytes: bytes) { success = true }
        }

        return success
    }

    // MARK: - Public Control API

    func readFanSpeeds() {
        guard let fans = fanState?.fans, !fans.isEmpty else { return }

        if helperRunning {
            helperQueue.async { [weak self] in
                guard let self else { return }
                var speeds = [(Int, Double)]()
                for i in 0..<fans.count {
                    if let speed = self.privilegedReadDouble(key: "F\(fans[i].index)Ac") {
                        speeds.append((i, speed))
                    }
                }
                self.pendingFanSpeeds = speeds
            }
        } else {
            var speeds = [(Int, Double)]()
            for i in 0..<fans.count {
                if let current = smc.getFanCurrentSpeed(fanIndex: fans[i].index) {
                    speeds.append((i, current))
                }
            }
            pendingFanSpeeds = speeds
        }

        reevaluateCurveIfNeeded()
    }

    func applyReadings() {
        guard let speeds = pendingFanSpeeds else { return }
        pendingFanSpeeds = nil
        for (i, speed) in speeds {
            if i < (fanState?.fans.count ?? 0) {
                fanState?.fans[i].currentSpeed = speed
            }
        }
    }

    func setAllFansAuto() {
        resetToAutomatic()
    }

    func setAllFansSpeed(percentage: Double) {
        guard let fans = fanState?.fans else { return }
        let label = percentage == 100 ? "Max" : "\(Int(percentage))%"

        helperQueue.async { [weak self] in
            guard let self else { return }
            for retry in 0..<3 {
                for (i, fan) in fans.enumerated() {
                    let speed = fan.minSpeed + (fan.maxSpeed - fan.minSpeed) * (percentage / 100.0)
                    _ = self.setFanModeWrite(fanIndex: fan.index, mode: .forced)
                    _ = self.setFanTargetWrite(fanIndex: fan.index, speed: speed)
                    DispatchQueue.main.async {
                        if i < (self.fanState?.fans.count ?? 0) {
                            self.fanState?.fans[i].targetSpeed = speed
                            self.fanState?.fans[i].isManual = true
                            self.fanState?.fans[i].selectedSpeedLabel = label
                        }
                    }
                }
                Thread.sleep(forTimeInterval: 0.3)
                if let mdVal = self.privilegedReadDouble(key: "F0Md"), mdVal == 1.0 { break }
                _ = self.smcWrite(key: "Ftst", bytes: [0x01])
                Thread.sleep(forTimeInterval: 0.5)
                self.forceTestModeActive = false
            }
        }
    }

    func setControlMode(_ mode: FanControlMode) {
        fanState?.controlMode = mode
        switch mode {
        case .automatic:
            fanState?.activeCurve = nil
            curveFansForced = false
            lastCurveAboveZero = .distantPast
            DispatchQueue.main.async { self.fanState?.isCurveCooldownActive = false }
            resetToAutomatic()
            fanState?.isControlActive = false
        case .manual:
            fanState?.activeCurve = nil
            curveFansForced = false
            DispatchQueue.main.async { self.fanState?.isCurveCooldownActive = false }
            fanState?.isControlActive = true
            applyManualSpeed()
        case .curve:
            curveFansForced = false
            DispatchQueue.main.async { self.fanState?.isCurveCooldownActive = false }
            fanState?.isControlActive = true
        }
    }

    func applyManualSpeed() {
        guard let fans = fanState?.fans else { return }
        let pct = fanState?.manualSpeedPercentage ?? 50.0

        helperQueue.async { [weak self] in
            guard let self else { return }
            for retry in 0..<3 {
                for (i, fan) in fans.enumerated() {
                    let speed = fan.minSpeed + (fan.maxSpeed - fan.minSpeed) * (pct / 100.0)
                    _ = self.setFanModeWrite(fanIndex: fan.index, mode: .forced)
                    _ = self.setFanTargetWrite(fanIndex: fan.index, speed: speed)
                    DispatchQueue.main.async {
                        if i < (self.fanState?.fans.count ?? 0) {
                            self.fanState?.fans[i].targetSpeed = speed
                            self.fanState?.fans[i].isManual = true
                        }
                    }
                }
                Thread.sleep(forTimeInterval: 0.3)
                if let mdVal = self.privilegedReadDouble(key: "F0Md"), mdVal == 1.0 { break }
                _ = self.smcWrite(key: "Ftst", bytes: [0x01])
                Thread.sleep(forTimeInterval: 0.5)
                self.forceTestModeActive = false
            }
        }
    }

    func applyFanCurveSpeed(temperature: Double, curve: FanCurve, allowImmediateOff: Bool = false) {
        let percentage = curve.speedForTemperature(temperature)
        guard let fans = fanState?.fans else { return }
        let now = Date()

        if percentage > 0 {
            lastCurveAboveZero = now
            DispatchQueue.main.async { self.fanState?.isCurveCooldownActive = false }
        }

        if percentage <= 0 {
            let sinceLastAbove = now.timeIntervalSince(lastCurveAboveZero)
            if allowImmediateOff || curveFansForced {
                if allowImmediateOff || sinceLastAbove >= curveModeTransitionCooldown {
                    curveFansForced = false
                    resetToAutomatic()
                    DispatchQueue.main.async {
                        self.fanState?.controlMode = .curve
                        self.fanState?.isCurveCooldownActive = false
                    }
                } else {
                    DispatchQueue.main.async { self.fanState?.isCurveCooldownActive = true }
                }
            }
            return
        }

        if !curveFansForced { curveFansForced = true }
        DispatchQueue.main.async { self.fanState?.isCurveCooldownActive = false }

        helperQueue.async { [weak self] in
            guard let self else { return }
            for retry in 0..<3 {
                for (i, fan) in fans.enumerated() {
                    let speed = fan.minSpeed + (fan.maxSpeed - fan.minSpeed) * (percentage / 100.0)
                    _ = self.setFanModeWrite(fanIndex: fan.index, mode: .forced)
                    _ = self.setFanTargetWrite(fanIndex: fan.index, speed: speed)
                    DispatchQueue.main.async {
                        if i < (self.fanState?.fans.count ?? 0) {
                            self.fanState?.fans[i].targetSpeed = speed
                            self.fanState?.fans[i].isManual = true
                        }
                    }
                }
                Thread.sleep(forTimeInterval: 0.3)
                if let mdVal = self.privilegedReadDouble(key: "F0Md"), mdVal == 1.0 { break }
                _ = self.smcWrite(key: "Ftst", bytes: [0x01])
                Thread.sleep(forTimeInterval: 0.5)
                self.forceTestModeActive = false
            }
        }
    }

    private func resetToAutomatic() {
        guard let fans = fanState?.fans else { return }

        helperQueue.async { [weak self] in
            guard let self else { return }
            self.disableForceTestMode()
            for fan in fans {
                _ = self.setFanModeWrite(fanIndex: fan.index, mode: .automatic)
            }
            DispatchQueue.main.async {
                for i in 0..<(self.fanState?.fans.count ?? 0) {
                    self.fanState?.fans[i].isManual = false
                    self.fanState?.fans[i].selectedSpeedLabel = "Auto"
                }
            }
        }
    }

    private func reevaluateCurveIfNeeded() {
        guard fanState?.controlMode == .curve,
              let curve = fanState?.activeCurve else { return }
        let temp = curveSensorTemp(for: curve.sensorKey)
        guard temp > 0 else { return }
        applyFanCurveSpeed(temperature: temp, curve: curve)
    }

    private func curveSensorTemp(for key: String) -> Double {
        guard let sensorState else { return 0 }
        switch key {
        case "AGG_CPU_AVG": return sensorState.averageCPUTemp
        case "AGG_CPU_MAX": return sensorState.hottestCPUTemp
        case "AGG_GPU_AVG": return sensorState.averageGPUTemp
        default:
            return sensorState.temperatureReadings.first(where: { $0.key == key })?.value ?? 0
        }
    }
}
