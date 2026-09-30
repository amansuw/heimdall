import Foundation

/// Drives the fans, through the root helper when it is connected.
///
/// Threading — the unchecked Sendable conformance rests on this confinement:
/// - `@MainActor` members own everything the UI sees (`fanState`, `sensorState`)
///   and the curve bookkeeping. Control requests arrive there.
/// - `helperQueue` owns the helper connection (`helperRunning`, `sockFd`,
///   `rspBuffer`), force-test mode, the discovered fan indices and the factory
///   minimums. Every SMC write and privileged read runs on it, so the ~2.4 s write
///   sequences never block the main thread or the monitor's timers.
/// - `applyLock` guards the handoff state both sides touch: pending fan speeds and
///   the coalescing generation.
final class FanController: @unchecked Sendable {
    @MainActor weak var fanState: FanState?
    @MainActor weak var sensorState: SensorState?

    private let smc = SMCKit.shared
    private let helperQueue = DispatchQueue(label: "com.heimdall.fan", qos: .userInitiated)

    // MARK: helperQueue only

    private var helperRunning = false
    /// One authenticated stream socket to the root helper.
    private var sockFd: Int32 = -1
    private var rspBuffer = Data()
    private var forceTestModeActive = false
    /// Whether the app wants the helper to keep the SoC energy counters
    /// publishing. Re-sent on every connect, since the helper drops it when a
    /// session ends.
    private var energyReportingWanted = false
    private var energyLeaseRenewed: Date = .distantPast

    /// Fan indices captured at discovery, in the same order as `fanState.fans`.
    private var fanIndices: [Int] = []

    /// Lowest F<i>Mn ever observed per fan — see recordFactoryMinimum.
    private var factoryMinimums: [Int: Double] = [:]
    private static let factoryMinimumsKey = "heimdall.factoryFanMinimums"

    // MARK: Main actor only

    @MainActor private var curveFansForced = false
    @MainActor private var lastCurveAboveZero: Date = .distantPast
    private let curveModeTransitionCooldown: TimeInterval = 30

    // MARK: Guarded by applyLock

    private let applyLock = NSLock()
    /// Speeds read on helperQueue, waiting for the main thread to publish them.
    private var pendingFanSpeeds: [(Int, Double)]?
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

    // MARK: - Discovery

    /// Reads the fan inventory on helperQueue, which owns it, and publishes it.
    func discoverFans() {
        helperQueue.async { [weak self] in
            guard let self else { return }
            self.loadFactoryMinimums()

            let numFans = max(self.smc.getNumberOfFans(), 0)
            var discovered: [FanInfo] = []
            for i in 0..<numFans {
                let current = self.smc.getFanCurrentSpeed(fanIndex: i)
                let liveMin = self.smc.getFanMinSpeed(fanIndex: i)
                let max = self.smc.getFanMaxSpeed(fanIndex: i)
                let target = self.smc.getFanTargetSpeed(fanIndex: i)

                discovered.append(FanInfo(
                    id: i, index: i,
                    currentSpeed: current ?? 0,
                    minSpeed: self.recordFactoryMinimum(fanIndex: i, observed: liveMin),
                    maxSpeed: max ?? 6500, targetSpeed: target ?? (current ?? 0),
                    isManual: false
                ))
            }
            self.fanIndices = Array(0..<numFans)

            // Probing write access performs an SMC write.
            let directWrite = self.smc.testWriteAccess()
            let fans = discovered

            DispatchQueue.main.async {
                self.fanState?.fans = fans
                self.fanState?.hasWriteAccess = (self.fanState?.hasWriteAccess ?? false) || directWrite
            }
        }
    }

    // MARK: - Factory Fan Minimums (helperQueue)

    // Forcing a fan writes F<i>Mn, and the SMC keeps that value after the app exits.
    // Reading F<i>Mn at the next launch therefore returns the *forced* speed and treats
    // it as the fan's floor, which ratchets the minimum upward every session and skews
    // both speedPercentage and curve output. Track the lowest value ever seen instead,
    // and put it back whenever control is released.

    private func loadFactoryMinimums() {
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.factoryMinimumsKey) as? [String: Double] else { return }
        factoryMinimums = raw.reduce(into: [:]) { acc, entry in
            if let index = Int(entry.key) { acc[index] = entry.value }
        }
    }

    /// Returns the baseline minimum for a fan, narrowing it if this reading is lower.
    /// Self-healing: once the SMC is back at its factory floor (after a reset or a
    /// clean quit) that lower value is captured and kept.
    @discardableResult
    private func recordFactoryMinimum(fanIndex: Int, observed: Double?) -> Double {
        guard let observed, observed > 0 else { return factoryMinimums[fanIndex] ?? 0 }
        let baseline = Swift.min(factoryMinimums[fanIndex] ?? observed, observed)
        if factoryMinimums[fanIndex] != baseline {
            factoryMinimums[fanIndex] = baseline
            var raw = UserDefaults.standard.dictionary(forKey: Self.factoryMinimumsKey) as? [String: Double] ?? [:]
            raw["\(fanIndex)"] = baseline
            UserDefaults.standard.set(raw, forKey: Self.factoryMinimumsKey)
        }
        return baseline
    }

    private func restoreFactoryMinimum(fanIndex: Int) {
        guard let baseline = factoryMinimums[fanIndex], baseline > 0,
              let val = smc.readKey("F\(fanIndex)Mn") else { return }
        _ = smcWrite(key: "F\(fanIndex)Mn", bytes: smc.encodeSpeed(baseline, dataType: val.dataType))
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

    @MainActor
    func requestAdminAccess() {
        guard let fanState, !fanState.isRequestingAccess else { return }
        fanState.isRequestingAccess = true
        fanState.accessError = nil

        helperQueue.async { [weak self] in
            guard let self else { return }

            self.closePersistentFDs()

            // Only a helper installed from this exact build will admit this app, so an
            // installed one is worth waiting for; any other gets replaced.
            if SMCDaemon.isDaemonInstalled(), self.waitForDaemon(upTo: 10) {
                self.onDaemonConnected()
                return
            }

            switch SMCDaemon.installDaemon() {
            case .installed:
                if self.waitForDaemon(upTo: 15) {
                    self.onDaemonConnected()
                } else {
                    self.finishAccessRequest(error: "The helper was installed but did not start. Its log is at \(SMCDaemon.logPath).")
                }
            case .cancelled:
                self.finishAccessRequest(error: nil)
            case .failed(let message):
                self.finishAccessRequest(error: message)
            }
        }
    }

    /// Polls until the helper's socket exists and the helper admits this app.
    private func waitForDaemon(upTo timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if SMCDaemon.isDaemonRunning(), connectToDaemon() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    /// Ends a request that did not connect. Failing used to be silent: the button
    /// simply stopped spinning.
    private func finishAccessRequest(error: String?) {
        DispatchQueue.main.async {
            self.fanState?.isRequestingAccess = false
            self.fanState?.accessError = error
        }
    }

    private func connectToDaemon() -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var addr = SMCDaemon.socketAddress(SMCDaemon.socketPath)
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        guard ok == 0 else { Darwin.close(fd); return false }

        sockFd = fd
        helperRunning = true
        rspBuffer = Data()

        // connect() succeeds even when the helper is about to refuse this app and close
        // the socket, so only a PONG from this helper version counts as connected.
        guard sendCommand("PING", timeout: 2) == "PONG \(HelperInstaller.versionTag)" else {
            helperRunning = false
            closePersistentFDs()
            return false
        }
        if energyReportingWanted {
            _ = sendCommand("ENERGY ON")
            energyLeaseRenewed = Date()
        }
        return true
    }

    /// Asks the helper to keep CPU energy publishing. Without the helper CPU
    /// power reads "—". Called on every fast tick; ON is a 60s lease on the
    /// helper side, renewed every 20s.
    func setEnergyReporting(_ on: Bool) {
        helperQueue.async { [weak self] in
            guard let self else { return }
            let changed = self.energyReportingWanted != on
            self.energyReportingWanted = on
            if on {
                guard changed || Date().timeIntervalSince(self.energyLeaseRenewed) > 20 else { return }
                if self.sendCommand("ENERGY ON") != nil { self.energyLeaseRenewed = Date() }
            } else if changed {
                _ = self.sendCommand("ENERGY OFF")
                self.energyLeaseRenewed = .distantPast
            }
        }
    }

    private func onDaemonConnected() {
        let numFans = smc.getNumberOfFans()
        var allOk = true
        for i in 0..<numFans {
            if !setFanModeWrite(fanIndex: i, mode: .automatic) { allOk = false }
        }
        let succeeded = allOk

        DispatchQueue.main.async { [weak self] in
            self?.fanState?.hasWriteAccess = succeeded
            self?.fanState?.isRequestingAccess = false
            self?.fanState?.accessError = succeeded
                ? nil
                : "The helper is running but could not change the fans. Its log is at \(SMCDaemon.logPath)."
        }
    }

    private func closePersistentFDs() {
        if sockFd >= 0 { Darwin.close(sockFd); sockFd = -1 }
    }

    private func tryReconnectToDaemon(waitUpTo timeout: TimeInterval) -> Bool {
        if helperRunning && sockFd >= 0 { return true }

        closePersistentFDs()
        // A helper from another build — after an update, say — would refuse this app,
        // so don't spend the launch waiting on it. Enabling fan control reinstalls it.
        guard SMCDaemon.isDaemonInstalled() else { return false }
        return waitForDaemon(upTo: timeout)
    }

    /// Blocking teardown for applicationWillTerminate.
    ///
    /// Ordering matters: the fans must be handed back to the firmware and their
    /// minimums restored while the privileged connection is still open. Closing it
    /// first drops these writes onto the unprivileged path, where they cannot succeed
    /// — which is why quitting used to leave fans forced.
    func shutdown() {
        helperQueue.sync {
            for index in self.fanIndices {
                _ = self.setFanModeWrite(fanIndex: index, mode: .automatic)
                self.restoreFactoryMinimum(fanIndex: index)
            }
            if self.forceTestModeActive {
                _ = self.smcWrite(key: "Ftst", bytes: [0x00])
                self.forceTestModeActive = false
            }
            self.helperRunning = false
            self.closePersistentFDs()
        }
    }

    // MARK: - Helper Protocol (helperQueue)

    private func sendCommand(_ command: String, timeout: TimeInterval = 5) -> String? {
        guard helperRunning, sockFd >= 0 else { return nil }

        let cmdBytes = Array((command + "\n").utf8)
        let written = cmdBytes.withUnsafeBufferPointer { ptr -> Int in
            Darwin.write(sockFd, ptr.baseAddress!, ptr.count)
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
            let n = Darwin.read(sockFd, &buf, buf.count)
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

    // MARK: - thermalmonitord Unlock (helperQueue)

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

    // MARK: - Fan Mode/Speed Writes (helperQueue)

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

    // MARK: - Readings

    /// Called from the monitor's fast queue. The reads run on helperQueue, which owns
    /// the fan list and the helper connection; `applyReadings` publishes them.
    func readFanSpeeds() {
        helperQueue.async { [weak self] in
            guard let self, !self.fanIndices.isEmpty else { return }
            var speeds: [(Int, Double)] = []
            for (position, index) in self.fanIndices.enumerated() {
                let speed = self.helperRunning
                    ? self.privilegedReadDouble(key: "F\(index)Ac")
                    : self.smc.getFanCurrentSpeed(fanIndex: index)
                if let speed { speeds.append((position, speed)) }
            }
            self.applyLock.withLock { self.pendingFanSpeeds = speeds }
        }
    }

    /// Publishes the latest fan speeds and lets curve control react to the sensors
    /// the same tick has just published.
    @MainActor
    func applyReadings() {
        let speeds: [(Int, Double)]? = applyLock.withLock {
            defer { pendingFanSpeeds = nil }
            return pendingFanSpeeds
        }
        if let speeds, let fanState {
            for (i, speed) in speeds where i < fanState.fans.count {
                fanState.fans[i].currentSpeed = speed
            }
        }
        reevaluateCurveIfNeeded()
    }

    // MARK: - Public Control API

    @MainActor
    func setAllFansAuto() {
        resetToAutomatic()
    }

    @MainActor
    func setAllFansSpeed(percentage: Double) {
        forceFans(toPercent: percentage, label: percentage == 100 ? "Max" : "\(Int(percentage))%")
    }

    // MARK: - Coalesced Forced Writes

    private func nextApplyGeneration() -> UInt64 {
        applyLock.withLock {
            applyGeneration &+= 1
            return applyGeneration
        }
    }

    private func isCurrentGeneration(_ generation: UInt64) -> Bool {
        applyLock.withLock { generation == applyGeneration }
    }

    private func markApplied(percentage: Double) {
        applyLock.withLock {
            lastAppliedPercentage = percentage
            lastAppliedAt = Date()
        }
    }

    /// Forgets the last applied target so the next request always reaches the SMC.
    private func invalidateLastApplied() {
        applyLock.withLock {
            lastAppliedPercentage = nil
            lastAppliedAt = .distantPast
        }
    }

    /// True when `percentage` is close enough to what we already wrote — and written recently
    /// enough — that repeating the ~2.4s write sequence would be pure churn.
    private func shouldSkipApply(percentage: Double, epsilon: Double) -> Bool {
        applyLock.withLock {
            guard let last = lastAppliedPercentage else { return false }
            guard Date().timeIntervalSince(lastAppliedAt) < applyRefreshInterval else { return false }
            return abs(last - percentage) < epsilon
        }
    }

    /// Single implementation of the forced-speed write sequence used by manual, preset and
    /// curve control. Requests are coalesced: only the newest one performs SMC writes, so a
    /// slider drag no longer leaves the fans chasing dozens of stale setpoints.
    @MainActor
    private func forceFans(toPercent percentage: Double, label: String? = nil) {
        guard let fanState, !fanState.fans.isEmpty else { return }
        let fans = fanState.fans
        let targets = fans.map { $0.minSpeed + ($0.maxSpeed - $0.minSpeed) * (percentage / 100.0) }

        // Reflect the request in the UI immediately, whether or not the writes are skipped.
        for i in 0..<min(fanState.fans.count, targets.count) {
            fanState.fans[i].targetSpeed = targets[i]
            fanState.fans[i].isManual = true
            if let label { fanState.fans[i].selectedSpeedLabel = label }
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

    @MainActor
    func setControlMode(_ mode: FanControlMode) {
        fanState?.controlMode = mode
        // A mode switch must always reach the SMC, even if the target percentage is unchanged.
        invalidateLastApplied()
        switch mode {
        case .automatic:
            fanState?.activeCurve = nil
            curveFansForced = false
            lastCurveAboveZero = .distantPast
            fanState?.isCurveCooldownActive = false
            resetToAutomatic()
            fanState?.isControlActive = false
        case .manual:
            fanState?.activeCurve = nil
            curveFansForced = false
            fanState?.isCurveCooldownActive = false
            fanState?.isControlActive = true
            applyManualSpeed()
        case .curve:
            curveFansForced = false
            fanState?.isCurveCooldownActive = false
            fanState?.isControlActive = true
        }
    }

    @MainActor
    func applyManualSpeed() {
        forceFans(toPercent: fanState?.manualSpeedPercentage ?? 50.0)
    }

    @MainActor
    func applyFanCurveSpeed(temperature: Double, curve: FanCurve, allowImmediateOff: Bool = false) {
        let percentage = curve.speedForTemperature(temperature)
        let now = Date()

        if percentage > 0 {
            lastCurveAboveZero = now
            fanState?.isCurveCooldownActive = false
        }

        if percentage <= 0 {
            let sinceLastAbove = now.timeIntervalSince(lastCurveAboveZero)
            if allowImmediateOff || curveFansForced {
                if allowImmediateOff || sinceLastAbove >= curveModeTransitionCooldown {
                    curveFansForced = false
                    resetToAutomatic()
                    fanState?.controlMode = .curve
                    fanState?.isCurveCooldownActive = false
                } else {
                    fanState?.isCurveCooldownActive = true
                }
            }
            return
        }

        curveFansForced = true
        fanState?.isCurveCooldownActive = false

        forceFans(toPercent: percentage)
    }

    private func resetToAutomatic() {
        // Fans are no longer forced, so the next forced request must not be deduped away.
        invalidateLastApplied()
        _ = nextApplyGeneration()

        helperQueue.async { [weak self] in
            guard let self else { return }
            self.disableForceTestMode()
            for index in self.fanIndices {
                _ = self.setFanModeWrite(fanIndex: index, mode: .automatic)
                self.restoreFactoryMinimum(fanIndex: index)
            }
            DispatchQueue.main.async {
                for i in 0..<(self.fanState?.fans.count ?? 0) {
                    self.fanState?.fans[i].isManual = false
                    self.fanState?.fans[i].selectedSpeedLabel = "Auto"
                }
            }
        }
    }

    @MainActor
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

    @MainActor
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
