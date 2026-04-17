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

    // Visibility-aware polling
    private var isWindowVisible = false
    private var isPopoverVisible = false
    private var sleepObserver: Any?
    private var wakeObserver: Any?
    private var isSleeping = false

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

        // Fast timer: CPU, GPU, RAM, Network, Fan speeds
        let fast = DispatchSource.makeTimerSource(queue: fastQueue)
        fast.schedule(deadline: .now(), repeating: fastInterval, leeway: .milliseconds(200))
        fast.setEventHandler { [weak self] in self?.fastTick() }
        fast.resume()
        fastSource = fast

        // Slow timer: Processes, battery, disk space, public IP
        let slow = DispatchSource.makeTimerSource(queue: slowQueue)
        slow.schedule(deadline: .now() + 1.0, repeating: 10.0, leeway: .seconds(1))
        slow.setEventHandler { [weak self] in self?.slowTick() }
        slow.resume()
        slowSource = slow

        // Sleep/wake observers
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
        isWindowVisible = visible
        updatePollingRate()
    }

    func setPopoverVisible(_ visible: Bool) {
        isPopoverVisible = visible
        updatePollingRate()
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

    private var fastInterval: TimeInterval {
        if let until = boostedPollingUntil, until > Date() {
            return 1.0
        }
        return (isWindowVisible || isPopoverVisible) ? 2.0 : 5.0
    }

    private var isBoostedPollingActive: Bool {
        guard let until = boostedPollingUntil else { return false }
        return until > Date()
    }

    private func updatePollingRate() {
        fastSource?.schedule(deadline: .now(), repeating: fastInterval, leeway: .milliseconds(200))
    }

    // MARK: - Fast Tick

    private func fastTick() {
        guard !isSleeping else { return }

        fastTickCount += 1

        let cpuResult = cpuReader.read()
        let ramResult = ramReader.read()
        let gpuResult = gpuReader.read()
        let netResult = networkReader.read()
        let diskIOResult = diskReader.readIO()

        // Sensors every 5th fast tick (every tick during temporary boost)
        var sensorResult: SensorReaderResult?
        if isBoostedPollingActive || fastTickCount % 5 == 0 {
            sensorResult = sensorReader.read()
        }

        // Fan speeds
        fanController?.readFanSpeeds()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.cpuState?.apply(cpuResult)
            self.ramState?.apply(ramResult)
            self.gpuState?.apply(gpuResult)
            self.networkState?.apply(netResult)
            self.diskState?.applyIO(diskIOResult)
            if let r = sensorResult { self.sensorState?.apply(r) }
            self.fanController?.applyReadings()
        }
    }

    // MARK: - Slow Tick

    private func slowTick() {
        guard !isSleeping else { return }

        slowTickCount += 1

        let cpuProcs = processReader.readTopCPU()
        let ramProcs = processReader.readTopRAM()
        let diskProcs = processReader.readTopDiskIO()
        let netProcs = processReader.readTopNetwork()

        // Disk space every 2nd slow tick (20s)
        var diskSpace: DiskSpaceResult?
        if slowTickCount % 2 == 0 {
            diskSpace = diskReader.readSpace()
        }

        let batteryResult = batteryReader.read()

        // Public IP every 6th slow tick (60s)
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
            self.cpuState?.topProcesses = cpuProcs
            self.ramState?.topProcesses = ramProcs
            self.diskState?.topProcesses = diskProcs
            self.networkState?.topProcesses = netProcs
            self.gpuState?.topProcesses = cpuProcs
            if let d = diskSpace { self.diskState?.applySpace(d) }
            self.batteryState?.apply(batteryResult)
        }
    }
}
