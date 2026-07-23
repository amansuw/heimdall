import SwiftUI
import AppKit

struct HeimdallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("Heimdall", id: "main") {
            ContentView()
                .environment(appDelegate.cpuState)
                .environment(appDelegate.gpuState)
                .environment(appDelegate.ramState)
                .environment(appDelegate.diskState)
                .environment(appDelegate.networkState)
                .environment(appDelegate.batteryState)
                .environment(appDelegate.sensorState)
                .environment(appDelegate.fanState)
                .environment(appDelegate.profileState)
                .frame(minWidth: 900, minHeight: 650)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1050, height: 750)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    // @Observable state objects
    let cpuState = CPUState()
    let gpuState = GPUState()
    let ramState = RAMState()
    let diskState = DiskState()
    let networkState = NetworkState()
    let batteryState = BatteryState()
    let sensorState = SensorState()
    let fanState = FanState()
    let profileState = ProfileState()
    let processHistory = ProcessHistory()

    // Coordinator & controllers
    private let coordinator = MonitorCoordinator()
    private let fanController = FanController()
    private let statusBarController = StatusBarController()
    private var menuBarDisplayTimer: DispatchSourceTimer?
    private var windowVisibilityObservers: [Any] = []

    // Notification observers
    private var observers: [Any] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        profileState.loadProfiles()
        setupCoordinator()
        setupStatusBar()
        setupNotificationHandlers()
        setupWindowVisibilityTracking()
        fanController.restoreWriteAccessSilently()

        // Discover fans on background queue
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.fanController.discoverFans()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
        fanController.shutdown()
        SMCKit.shared.resetAllFansToAutomatic()
    }

    // MARK: - Setup

    private func setupCoordinator() {
        coordinator.cpuState = cpuState
        coordinator.gpuState = gpuState
        coordinator.ramState = ramState
        coordinator.diskState = diskState
        coordinator.networkState = networkState
        coordinator.batteryState = batteryState
        coordinator.sensorState = sensorState
        coordinator.fanState = fanState
        coordinator.fanController = fanController
        coordinator.processHistory = processHistory

        cpuState.processHistory = processHistory
        gpuState.processHistory = processHistory
        ramState.processHistory = processHistory
        diskState.processHistory = processHistory
        networkState.processHistory = processHistory

        fanController.fanState = fanState
        fanController.sensorState = sensorState

        coordinator.start()
    }

    private func setupStatusBar() {
        let popoverView = PopoverView()
            .environment(cpuState)
            .environment(gpuState)
            .environment(ramState)
            .environment(diskState)
            .environment(networkState)
            .environment(batteryState)
            .environment(sensorState)
            .environment(fanState)
            .environment(profileState)

        let hostingController = NSHostingController(rootView: popoverView)
        statusBarController.cpuState = cpuState
        statusBarController.fanState = fanState
        statusBarController.sensorState = sensorState
        statusBarController.ramState = ramState
        statusBarController.networkState = networkState
        statusBarController.onPopoverVisibilityChanged = { [weak self] visible in
            self?.coordinator.setPopoverVisible(visible)
        }
        statusBarController.setup(popoverContent: hostingController)

        // Menu-bar tint tracks CPU temp — 30s matches background sample rate.
        let displayTimer = DispatchSource.makeTimerSource(queue: .main)
        displayTimer.schedule(deadline: .now(), repeating: 30.0, leeway: .seconds(1))
        displayTimer.setEventHandler { [weak self] in
            self?.statusBarController.updateWidget()
        }
        displayTimer.resume()
        menuBarDisplayTimer = displayTimer
    }

    private func setupWindowVisibilityTracking() {
        let center = NotificationCenter.default

        let handler: (Notification) -> Void = { [weak self] _ in
            self?.refreshMainWindowVisibility()
        }

        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification,
            NSWindow.didChangeOcclusionStateNotification
        ] {
            windowVisibilityObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main, using: handler)
            )
        }

        // Initial state after windows exist.
        DispatchQueue.main.async { [weak self] in
            self?.refreshMainWindowVisibility()
        }
    }

    private func refreshMainWindowVisibility() {
        // Main dashboard is a large titled window; status-item chrome is not.
        let visible = NSApp.windows.contains { window in
            guard window.styleMask.contains(.titled) else { return false }
            guard window.frame.width >= 700 else { return false }
            return window.isVisible
                && !window.isMiniaturized
                && window.occlusionState.contains(.visible)
        }
        coordinator.setWindowVisible(visible)
    }

    private func setupNotificationHandlers() {
        observers.append(
            NotificationCenter.default.addObserver(forName: .requestFanAccess, object: nil, queue: .main) { [weak self] _ in
                self?.fanController.requestAdminAccess()
            }
        )

        observers.append(
            NotificationCenter.default.addObserver(forName: .fanControlModeChanged, object: nil, queue: .main) { [weak self] notif in
                if let mode = notif.object as? FanControlMode {
                    self?.fanController.setControlMode(mode)
                    self?.coordinator.boostFastPollingTemporarily()
                }
            }
        )

        observers.append(
            NotificationCenter.default.addObserver(forName: .fanSetAllAuto, object: nil, queue: .main) { [weak self] _ in
                self?.fanController.setAllFansAuto()
                self?.coordinator.boostFastPollingTemporarily()
            }
        )

        observers.append(
            NotificationCenter.default.addObserver(forName: .fanSetAllSpeed, object: nil, queue: .main) { [weak self] notif in
                if let speed = notif.object as? Double {
                    self?.fanController.setAllFansSpeed(percentage: speed)
                    self?.coordinator.boostFastPollingTemporarily()
                }
            }
        )

        observers.append(
            NotificationCenter.default.addObserver(forName: .fanApplyManual, object: nil, queue: .main) { [weak self] _ in
                self?.fanController.applyManualSpeed()
                self?.coordinator.boostFastPollingTemporarily()
            }
        )
    }
}
