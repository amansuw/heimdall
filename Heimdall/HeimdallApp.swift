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
        // shutdown() restores automatic control and the factory fan minimums itself,
        // through the privileged helper, before tearing that connection down. The old
        // unprivileged SMCKit reset here ran after the helper was already gone.
        fanController.shutdown()
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
            DispatchQueue.main.async { self?.refreshMainWindowVisibility() }
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
        let mainWindows = NSApp.windows.filter {
            $0.styleMask.contains(.titled) && $0.frame.width >= 700
        }

        // Polling cadence follows what the user can actually see right now.
        let visible = mainWindows.contains { window in
            window.isVisible
                && !window.isMiniaturized
                && window.occlusionState.contains(.visible)
        }
        coordinator.setWindowVisible(visible)

        // Cmd-Tab presence is a different question: a minimised window still belongs
        // in the switcher, a closed one does not. Hence the separate test.
        let hasOpenWindow = mainWindows.contains { $0.isVisible || $0.isMiniaturized }
        updateActivationPolicy(showInSwitcher: hasOpenWindow)
    }

    /// Heimdall launches as an accessory (LSUIElement) so it lives in the menu bar
    /// without a Dock tile. While the main window is open it becomes a regular app so
    /// it appears in Cmd-Tab and the Dock, then drops back to accessory on close.
    private func updateActivationPolicy(showInSwitcher: Bool) {
        let desired: NSApplication.ActivationPolicy = showInSwitcher ? .regular : .accessory
        guard NSApp.activationPolicy() != desired else { return }
        NSApp.setActivationPolicy(desired)

        // Promoting to .regular does not focus the app on its own.
        if desired == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }
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
