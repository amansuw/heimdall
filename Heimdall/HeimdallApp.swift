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
                .environment(AppSettings.shared)
                .frame(minWidth: 900, minHeight: 650)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1050, height: 750)
        .commands {
            // Without these the standard Edit shortcuts do not exist, so text fields
            // in the curve editor and the rename dialog had no Cmd-A/C/V/Z.
            TextEditingCommands()
        }

        Settings {
            SettingsView()
                .environment(AppSettings.shared)
                .environment(appDelegate.fanState)
        }
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

    let settings = AppSettings.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The login-item state can change outside the app (System Settings), so
        // re-read it rather than trusting what was stored.
        settings.refreshLaunchAtLogin()
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

    /// Reopen (Dock click, or `open` on an already-running copy). The menu bar
    /// popover is the primary way back to the dashboard, but when AppKit still has
    /// the window object around this restores it without going through the popover.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        if let existing = NSApp.windows.first(where: {
            $0.styleMask.contains(.titled) && $0.frame.width >= 700
        }) {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            refreshMainWindowVisibility()
        }
        return true
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

        // Cheap: reads already-sampled state, issues no SMC calls. Kept short so a
        // menu bar readout tracks the sampler instead of lagging a whole cycle.
        let displayTimer = DispatchSource.makeTimerSource(queue: .main)
        displayTimer.schedule(deadline: .now(), repeating: 5.0, leeway: .seconds(1))
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
