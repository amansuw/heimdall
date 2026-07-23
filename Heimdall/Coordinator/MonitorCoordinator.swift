import Foundation
import AppKit

class MonitorCoordinator {
    // State objects (owned by AppDelegate, passed here)
    var cpuState: CPUState?
    var gpuState: GPUState?
    var ramState: RAMState?
    var diskState: DiskState?
    var networkState: NetworkState?
    var batteryState: BatteryState?
    var sensorState: SensorState?
    var fanState: FanState?

    // Readers (owned here)
    let cpuReader = CPUReader()
    let gpuReader = GPUReader()
    let ramReader = RAMReader()
    let diskReader = DiskReader()
    let networkReader = NetworkReader()
    let batteryReader = BatteryReader()
    let sensorReader = SensorReader()
    let processReader = ProcessReader()
    var processHistory: ProcessHistory!

    // Fan controller
    var fanController: FanController?

    // Dispatch
    private let fastQueue = DispatchQueue(label: "com.heimdall.monitor.fast", qos: .utility)
    private let slowQueue = DispatchQueue(label: "com.heimdall.monitor.slow", qos: .utility)
    private var fastSource: DispatchSourceTimer?
    private var slowSource: DispatchSourceTimer?
    private var fastTickCount = 0
    private var slowTickCount = 0
    private var boostedPollingUntil: Date?

    // Visibility-aware polling — menu-bar-only uses a deep low-power path
    private var isWindowVisible = false
    private var isPopoverVisible = false
    private var sleepObserver: Any?
    private var wakeObserver: Any?
    private var isSleeping = false

    private var isUIActive: Bool { isWindowVisible || isPopoverVisible }

    func start() {
        // Discover sensors on first launch
        fastQueue.async { [weak self] in
            self?.sensorReader.discoverSensors()
            DispatchQueue.main.async {
                self?.sensorState?.isDiscovering = false
            }
        }

        // Apply CPU topology
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.cpuState?.applyTopology(total: self.cpuReader.totalCores, e: self.cpuReader.eCores, p: self.cpuReader.pCores)
        }

        // Fetch DNS servers once
        fastQueue.async { [weak self] in
            guard let self else { return }
            let servers = self.networkReader.fetchDNSServers()
            DispatchQueue.main.async {
                self.networkState?.stats.dnsServers = servers
            }
        }

        let fast = DispatchSource.makeTimerSource(queue: fastQueue)
        fast.schedule(deadline: .now(), repeating: fastInterval, leeway: .milliseconds(500))
        fast.setEventHandler { [weak self] in self?.fastTick() }
        fast.resume()
        fastSource = fast

        let slow = DispatchSource.makeTimerSource(queue: slowQueue)
        slow.schedule(deadline: .now() + 2.0, repeating: slowInterval, leeway: .seconds(2))
        slow.setEventHandler { [weak self] in self?.slowTick() }
        slow.resume()
        slowSource = slow

        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.isSleeping = true
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.isSleeping = false
        }
    }

    func stop() {
        fastSource?.cancel()
        fastSource = nil
        slowSource?.cancel()
        slowSource = nil

        if let obs = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
    }

    func setWindowVisible(_ visible: Bool) {
        guard isWindowVisible != visible else { return }
        isWindowVisible = visible
        updatePollingRate()
        if visible {
            // Catch up immediately when the main window opens.
            fastQueue.async { [weak self] in self?.fastTick() }
            slowQueue.async { [weak self] in self?.slowTick() }
        }
    }

    func setPopoverVisible(_ visible: Bool) {
        guard isPopoverVisible != visible else { return }
        isPopoverVisible = visible
        updatePollingRate()
        if visible {
            fastQueue.async { [weak self] in self?.fastTick() }
        }
    }

    func boostFastPollingTemporarily(duration: TimeInterval = 5) {
        boostedPollingUntil = Date().addingTimeInterval(duration)
        updatePollingRate()

        fastQueue.asyncAfter(deadline: .now() + duration + 0.1) { [weak self] in
            guard let self else { return }
            if let until = self.boostedPollingUntil, until <= Date() {
                self.boostedPollingUntil = nil
                self.updatePollingRate()
            }
        }
    }

    // MARK: - Polling Rate

    /// UI open: 2s. Fan boost: 1s. Menu-bar only: 30s (keeps chart history filled).
    private var fastInterval: TimeInterval {
        if let until = boostedPollingUntil, until > Date() {
            return 1.0
        }
        return isUIActive ? 2.0 : 30.0
    }

    /// UI open: 10s (processes/nettop). Menu-bar only: 60s (battery only, no nettop).
    private var slowInterval: TimeInterval {
        isUIActive ? 10.0 : 60.0
    }

    private var isBoostedPollingActive: Bool {
        guard let until = boostedPollingUntil else { return false }
        return until > Date()
    }

    private func updatePollingRate() {
        fastSource?.schedule(deadline: .now(), repeating: fastInterval, leeway: .milliseconds(500))
        slowSource?.schedule(deadline: .now() + 0.5, repeating: slowInterval, leeway: .seconds(2))
    }

    // MARK: - Fast Tick

    private func fastTick() {
        guard !isSleeping else { return }

        fastTickCount += 1
        let uiActive = isUIActive

        if !uiActive && !isBoostedPollingActive {
            // Background: full metric sample every 30s so charts stay continuous,
            // but skip the heavy process/nettop path (that's on the slow timer).
            let cpuResult = cpuReader.read()
            let ramResult = ramReader.read()
            let gpuResult = gpuReader.read()
            let netResult = networkReader.read()
            let diskIOResult = diskReader.readIO()
            let sensorResult = sensorReader.read()
            fanController?.readFanSpeeds()

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.cpuState?.apply(cpuResult, recordHistory: true)
                self.ramState?.apply(ramResult, recordHistory: true)
                self.gpuState?.apply(gpuResult, recordHistory: true)
                self.networkState?.apply(netResult, recordHistory: true)
                self.diskState?.applyIO(diskIOResult, recordHistory: true)
                if let sensorResult {
                    self.sensorState?.apply(sensorResult, recordHistory: true)
                }
                self.fanController?.applyReadings()
            }
            return
        }

        let cpuResult = cpuReader.read()
        let ramResult = ramReader.read()
        let gpuResult = gpuReader.read()
        let netResult = networkReader.read()
        let diskIOResult = diskReader.readIO()

        var sensorResult: SensorReaderResult?
        if isBoostedPollingActive || fastTickCount % 5 == 0 {
            sensorResult = sensorReader.read()
        }

        fanController?.readFanSpeeds()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.cpuState?.apply(cpuResult, recordHistory: true)
            self.ramState?.apply(ramResult, recordHistory: true)
            self.gpuState?.apply(gpuResult, recordHistory: true)
            self.networkState?.apply(netResult, recordHistory: true)
            self.diskState?.applyIO(diskIOResult, recordHistory: true)
            if let r = sensorResult { self.sensorState?.apply(r, recordHistory: true) }
            self.fanController?.applyReadings()
        }
    }

    // MARK: - Slow Tick

    private func slowTick() {
        guard !isSleeping else { return }

        slowTickCount += 1
        let uiActive = isUIActive

        if !uiActive {
            // Background: battery only — skip process enumeration and nettop entirely.
            let batteryResult = batteryReader.read()
            DispatchQueue.main.async { [weak self] in
                self?.batteryState?.apply(batteryResult)
            }
            return
        }

        // Full process snapshot including nettop only while UI is visible.
        let snapshot = processReader.readTickSnapshot(includeNetwork: true)

        var diskSpace: DiskSpaceResult?
        if slowTickCount % 2 == 0 {
            diskSpace = diskReader.readSpace()
        }

        let batteryResult = batteryReader.read()

        if slowTickCount % 6 == 0 {
            networkReader.fetchPublicIP { [weak self] ipv4, ipv6 in
                DispatchQueue.main.async {
                    if let ip = ipv4 { self?.networkState?.stats.publicIP = ip }
                    if let ip6 = ipv6 { self?.networkState?.stats.publicIPv6 = ip6 }
                }
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.processHistory.append(snapshot)
            if let d = diskSpace { self.diskState?.applySpace(d) }
            self.batteryState?.apply(batteryResult)
        }
    }
}
