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

    /// Guards the coalescing state below, which is touched from both the caller's thread and
    /// `helperQueue`.
    private let applyLock = NSLock()
    /// Monotonic id for the newest requested target. A queued write block whose generation is
    /// stale has been superseded and exits without touching the SMC.
    private var applyGeneration: UInt64 = 0
    private var lastAppliedPercentage: Double?
    private var lastAppliedAt: Date = .distantPast

    /// A repeat request within this many percentage points is treated as a no-op.
    private let manualApplyEpsilon: Double = 0.5
    /// Curve re-evaluation only re-applies when the computed target moved at least this much.
    private let curveApplyEpsilon: Double = 2.0
    /// Re-apply an unchanged target at least this often, in case the SMC drifted back.
    private let applyRefreshInterval: TimeInterval = 60

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

        // Encode against the key's own data type rather than assuming fpe2.
        func encodeSpeed(_ key: String) -> [UInt8]? {
            guard let val = smc.readKey(key) else { return nil }
            return smc.encodeSpeed(speed, dataType: val.dataType)
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
        forceFans(toPercent: percentage, label: percentage == 100 ? "Max" : "\(Int(percentage))%")
    }

    // MARK: - Coalesced Forced Writes

    private func nextApplyGeneration() -> UInt64 {
        applyLock.lock()
        defer { applyLock.unlock() }
        applyGeneration &+= 1
        return applyGeneration
    }

    private func isCurrentGeneration(_ generation: UInt64) -> Bool {
        applyLock.lock()
        defer { applyLock.unlock() }
        return generation == applyGeneration
    }

    private func markApplied(percentage: Double) {
        applyLock.lock()
        lastAppliedPercentage = percentage
        lastAppliedAt = Date()
        applyLock.unlock()
    }

    /// Forgets the last applied target so the next request always reaches the SMC.
    private func invalidateLastApplied() {
        applyLock.lock()
        lastAppliedPercentage = nil
        lastAppliedAt = .distantPast
        applyLock.unlock()
    }

    /// True when `percentage` is close enough to what we already wrote — and written recently
    /// enough — that repeating the ~2.4s write sequence would be pure churn.
    private func shouldSkipApply(percentage: Double, epsilon: Double) -> Bool {
        applyLock.lock()
        defer { applyLock.unlock() }
        guard let last = lastAppliedPercentage else { return false }
        guard Date().timeIntervalSince(lastAppliedAt) < applyRefreshInterval else { return false }
        return abs(last - percentage) < epsilon
    }

    /// Single implementation of the forced-speed write sequence used by manual, preset and
    /// curve control. Requests are coalesced: only the newest one performs SMC writes, so a
    /// slider drag no longer leaves the fans chasing dozens of stale setpoints.
    private func forceFans(toPercent percentage: Double, label: String? = nil) {
        guard let fans = fanState?.fans, !fans.isEmpty else { return }

        let targets = fans.map { $0.minSpeed + ($0.maxSpeed - $0.minSpeed) * (percentage / 100.0) }

        // Reflect the request in the UI immediately, whether or not the writes are skipped.
        DispatchQueue.main.async { [weak self] in
            guard let self, let count = self.fanState?.fans.count else { return }
            for i in 0..<min(count, targets.count) {
                self.fanState?.fans[i].targetSpeed = targets[i]
                self.fanState?.fans[i].isManual = true
                if let label { self.fanState?.fans[i].selectedSpeedLabel = label }
            }
        }

        let generation = nextApplyGeneration()

        helperQueue.async { [weak self] in
            guard let self else { return }
            // Superseded while queued, or already at this target.
            guard self.isCurrentGeneration(generation) else { return }
            guard !self.shouldSkipApply(percentage: percentage, epsilon: self.manualApplyEpsilon) else { return }

            for _ in 0..<3 {
                for (i, fan) in fans.enumerated() {
                    _ = self.setFanModeWrite(fanIndex: fan.index, mode: .forced)
                    _ = self.setFanTargetWrite(fanIndex: fan.index, speed: targets[i])
                }
                self.markApplied(percentage: percentage)

                Thread.sleep(forTimeInterval: 0.3)
                if let mdVal = self.privilegedReadDouble(key: "F0Md"), mdVal == 1.0 { break }
                _ = self.smcWrite(key: "Ftst", bytes: [0x01])
                Thread.sleep(forTimeInterval: 0.5)
                self.forceTestModeActive = false

                // A newer target arrived mid-retry; let it take over.
                guard self.isCurrentGeneration(generation) else { return }
            }
        }
    }

    func setControlMode(_ mode: FanControlMode) {
        fanState?.controlMode = mode
        // A mode switch must always reach the SMC, even if the target percentage is unchanged.
        invalidateLastApplied()
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
        forceFans(toPercent: fanState?.manualSpeedPercentage ?? 50.0)
    }

    func applyFanCurveSpeed(temperature: Double, curve: FanCurve, allowImmediateOff: Bool = false) {
        let percentage = curve.speedForTemperature(temperature)
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

        forceFans(toPercent: percentage)
    }

    private func resetToAutomatic() {
        guard let fans = fanState?.fans else { return }

        // Fans are no longer forced, so the next forced request must not be deduped away.
        invalidateLastApplied()
        _ = nextApplyGeneration()

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

        // This runs on every fast tick (1-2s) while a write sequence takes ~2.4s, so only
        // enqueue one when the target has actually moved. The zero case still goes through so
        // the cooldown / reset-to-automatic logic keeps running.
        let target = curve.speedForTemperature(temp)
        if target > 0, curveFansForced,
           shouldSkipApply(percentage: target, epsilon: curveApplyEpsilon) {
            return
        }

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
