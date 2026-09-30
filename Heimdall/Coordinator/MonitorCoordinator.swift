import Foundation
import AppKit

/// Samples every reader on two timers and publishes the results to the main-actor
/// state objects.
///
/// Threading — the unchecked Sendable conformance rests on this confinement:
/// readers run only on `fastQueue` or `slowQueue`; state objects are touched only
/// on the main actor; the polling flags and timer sources that both the main thread
/// and the timer queues use live behind `pollingLock`.
final class MonitorCoordinator: @unchecked Sendable {
    // State objects (owned by AppDelegate, set before start()).
    @MainActor var cpuState: CPUState?
    @MainActor var gpuState: GPUState?
    @MainActor var ramState: RAMState?
    @MainActor var diskState: DiskState?
    @MainActor var networkState: NetworkState?
    @MainActor var batteryState: BatteryState?
    @MainActor var sensorState: SensorState?
    @MainActor var processHistory: ProcessHistory?
    @MainActor var powerState: PowerState?

    // Readers — each used only from the queue that samples it.
    let cpuReader = CPUReader()
    let gpuReader = GPUReader()
    let ramReader = RAMReader()
    let diskReader = DiskReader()
    let networkReader = NetworkReader()
    let batteryReader = BatteryReader()
    let sensorReader = SensorReader()
    let processReader = ProcessReader()
    let powerReader = PowerReader()

    let fanController: FanController

    // Dispatch
    private let fastQueue = DispatchQueue(label: "com.heimdall.monitor.fast", qos: .utility)
    private let slowQueue = DispatchQueue(label: "com.heimdall.monitor.slow", qos: .utility)
    /// slowQueue only.
    private var slowTickCount = 0

    /// What the main thread and the timer queues both read or write.
    private struct Polling {
        var fastSource: DispatchSourceTimer?
        var slowSource: DispatchSourceTimer?
        var boostedUntil: Date?
        // Visibility-aware polling — menu-bar-only uses a deep low-power path.
        var isWindowVisible = false
        var isPopoverVisible = false
        var isSleeping = false

        var isUIActive: Bool { isWindowVisible || isPopoverVisible }
    }
    private let pollingLock = NSLock()
    private var polling = Polling()

    @MainActor private var sleepObserver: Any?
    @MainActor private var wakeObserver: Any?

    init(fanController: FanController) {
        self.fanController = fanController
    }

    @MainActor
    func start() {
        // Apply CPU topology
        fastQueue.async { [weak self] in
            guard let self else { return }
            let total = self.cpuReader.totalCores
            let clusters = self.cpuReader.clusters
            DispatchQueue.main.async {
                self.cpuState?.applyTopology(total: total, clusters: clusters)
            }
        }

        // Discover sensors on first launch
        fastQueue.async { [weak self] in
            guard let self else { return }
            self.sensorReader.discoverSensors()
            DispatchQueue.main.async {
                self.sensorState?.isDiscovering = false
            }
        }

        // Fetch DNS servers once
        fastQueue.async { [weak self] in
            guard let self else { return }
            let servers = self.networkReader.fetchDNSServers()
            DispatchQueue.main.async {
                self.networkState?.stats.dnsServers = servers
            }
        }

        // @Sendable is load-bearing. setEventHandler does not require it, so a closure
        // written in this main-actor method would inherit main-actor isolation, and
        // Swift 6 traps the moment the timer fires on its own queue.
        let fast = DispatchSource.makeTimerSource(queue: fastQueue)
        fast.setEventHandler { @Sendable [weak self] in self?.fastTick() }
        let slow = DispatchSource.makeTimerSource(queue: slowQueue)
        slow.setEventHandler { @Sendable [weak self] in self?.slowTick() }

        pollingLock.withLock {
            polling.fastSource = fast
            polling.slowSource = slow
            fast.schedule(deadline: .now(), repeating: Self.fastInterval(for: polling), leeway: .milliseconds(500))
            slow.schedule(deadline: .now() + 2.0, repeating: Self.slowInterval(for: polling), leeway: .seconds(2))
        }
        fast.resume()
        slow.resume()

        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.setSleeping(true)
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.setSleeping(false)
        }
    }

    @MainActor
    func stop() {
        pollingLock.withLock {
            polling.fastSource?.cancel()
            polling.fastSource = nil
            polling.slowSource?.cancel()
            polling.slowSource = nil
        }

        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    func setWindowVisible(_ visible: Bool) {
        let opened = pollingLock.withLock { () -> Bool in
            guard polling.isWindowVisible != visible else { return false }
            polling.isWindowVisible = visible
            reschedule()
            return visible
        }
        if opened {
            // Catch up immediately when the main window opens.
            fastQueue.async { [weak self] in self?.fastTick() }
            slowQueue.async { [weak self] in self?.slowTick() }
        }
    }

    func setPopoverVisible(_ visible: Bool) {
        let opened = pollingLock.withLock { () -> Bool in
            guard polling.isPopoverVisible != visible else { return false }
            polling.isPopoverVisible = visible
            reschedule()
            return visible
        }
        if opened {
            fastQueue.async { [weak self] in self?.fastTick() }
        }
    }

    func boostFastPollingTemporarily(duration: TimeInterval = 5) {
        pollingLock.withLock {
            polling.boostedUntil = Date().addingTimeInterval(duration)
            reschedule()
        }

        fastQueue.asyncAfter(deadline: .now() + duration + 0.1) { [weak self] in
            guard let self else { return }
            self.pollingLock.withLock {
                if let until = self.polling.boostedUntil, until <= Date() {
                    self.polling.boostedUntil = nil
                    self.reschedule()
                }
            }
        }
    }

    private func setSleeping(_ sleeping: Bool) {
        pollingLock.withLock { polling.isSleeping = sleeping }
    }

    // MARK: - Polling Rate

    /// UI open: 2s. Fan boost: 1s. Menu-bar only: 30s (keeps chart history filled).
    private static func fastInterval(for polling: Polling) -> TimeInterval {
        if let until = polling.boostedUntil, until > Date() {
            return 1.0
        }
        if polling.isUIActive { return 2.0 }
        // A menu bar readout that only moves every 30s reads as broken, so opting
        // into one trades a little idle power for a usable refresh rate.
        return AppSettings.persistedMenuBarDisplay == .iconOnly ? 30.0 : 10.0
    }

    /// UI open: 10s (processes/nettop). Menu-bar only: 60s (battery only, no nettop).
    private static func slowInterval(for polling: Polling) -> TimeInterval {
        polling.isUIActive ? 10.0 : 60.0
    }

    /// Call with pollingLock held.
    private func reschedule() {
        polling.fastSource?.schedule(deadline: .now(), repeating: Self.fastInterval(for: polling), leeway: .milliseconds(500))
        polling.slowSource?.schedule(deadline: .now() + 0.5, repeating: Self.slowInterval(for: polling), leeway: .seconds(2))
    }

    // MARK: - Fast Tick

    private func fastTick() {
        guard !pollingLock.withLock({ polling.isSleeping }) else { return }
        // History is recorded with the window closed too, so CPU energy has to
        // keep publishing then. Turning it off with the window left a gap in the
        // power chart for every stretch in the menu bar. Asleep, no tick renews
        // the helper's 60s lease, so it lapses on its own.
        fanController.setEnergyReporting(true)

        // One sample set at every cadence: since sensors stopped being thinned to
        // every 5th tick, the background and visible paths were identical. What
        // differs is only how often this runs (fastInterval). The heavy
        // process/nettop work stays on the slow timer.
        let cpuResult = cpuReader.read()
        let ramResult = ramReader.read()
        let gpuResult = gpuReader.read()
        let netResult = networkReader.read()
        let diskIOResult = diskReader.readIO()
        let sensorResult = sensorReader.read()
        var power = powerReader.read()
        if let system = SMCKit.shared.readFloat("PSTR"), system.isFinite, system > 0 {
            power?.system = system
        }
        fanController.readFanSpeeds()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.cpuState?.apply(cpuResult, recordHistory: true)
            self.ramState?.apply(ramResult, recordHistory: true)
            self.gpuState?.apply(gpuResult, recordHistory: true)
            self.networkState?.apply(netResult, recordHistory: true)
            self.diskState?.applyIO(diskIOResult, recordHistory: true)
            if let sensorResult { self.sensorState?.apply(sensorResult, recordHistory: true) }
            if let power { self.powerState?.apply(power) }
            self.fanController.applyReadings()
        }
    }

    // MARK: - Slow Tick

    private func slowTick() {
        let (sleeping, uiActive) = pollingLock.withLock { (polling.isSleeping, polling.isUIActive) }
        guard !sleeping else { return }

        slowTickCount += 1

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
        let diskSpace = slowTickCount % 2 == 0 ? diskReader.readSpace() : nil
        let batteryResult = batteryReader.read()

        if slowTickCount % 6 == 0 {
            networkReader.fetchPublicIP { [weak self] ipv4, ipv6 in
                guard let self else { return }
                DispatchQueue.main.async {
                    if let ip = ipv4 { self.networkState?.stats.publicIP = ip }
                    if let ip6 = ipv6 { self.networkState?.stats.publicIPv6 = ip6 }
                }
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.processHistory?.append(snapshot)
            if let diskSpace { self.diskState?.applySpace(diskSpace) }
            self.batteryState?.apply(batteryResult)
        }
    }
}
