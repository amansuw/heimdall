import SwiftUI
import AppKit

struct HeimdallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // The dashboard is deliberately NOT a SwiftUI Window scene. An accessory
        // (LSUIElement) app does not get one presented at launch, and once closed
        // there is no supported way to bring it back — no Dock tile to click, and
        // openWindow is only reachable from a live view. AppDelegate owns the
        // window through AppKit instead, so it can be opened on demand, on first
        // run, and on reopen.
        Settings {
            SettingsView()
                .environment(AppSettings.shared)
                .environment(appDelegate.fanState)
                .environment(appDelegate.commands)
        }
        .commands {
            // Without these the standard Edit shortcuts do not exist, so text fields
            // in the curve editor and the rename dialog had no Cmd-A/C/V/Z.
            TextEditingCommands()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
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
    let powerState = PowerState()

    // Coordinator & controllers
    private let fanController = FanController()
    private lazy var coordinator = MonitorCoordinator(fanController: fanController)
    private let statusBarController = StatusBarController()
    private var menuBarDisplayTimer: DispatchSourceTimer?
    private var windowVisibilityObservers: [Any] = []

    /// The dashboard window, created on demand. Held so it can be re-shown.
    private var mainWindowController: NSWindowController?

    let settings = AppSettings.shared

    /// Handed to views through the environment in place of NotificationCenter posts.
    lazy var commands = AppCommands(
        fanController: fanController,
        coordinator: coordinator,
        showMainWindow: { [weak self] in self?.showMainWindow() }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The login-item state can change outside the app (System Settings), so
        // re-read it rather than trusting what was stored.
        settings.refreshLaunchAtLogin()
        profileState.loadProfiles()
        setupCoordinator()
        setupStatusBar()
        setupWindowVisibilityTracking()
        // Inventory first: both run on the fan controller's queue, and reconnecting can
        // spend several seconds waiting for a helper that is slow to start.
        fanController.discoverFans()
        fanController.restoreWriteAccessSilently()

        // Show the dashboard the first time Heimdall is ever run, so a new user
        // sees something other than a menu bar glyph they may not spot.
        if !settings.hasCompletedFirstRun {
            settings.hasCompletedFirstRun = true
            showMainWindow()
        }

    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Reopen: Dock click, or `open` on an already-running copy.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    /// Creates the dashboard window, or brings the existing one back to the front.
    func showMainWindow() {
        if let controller = mainWindowController, let window = controller.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            refreshMainWindowVisibility()
            return
        }

        let root = ContentView()
            .environment(cpuState)
            .environment(gpuState)
            .environment(ramState)
            .environment(diskState)
            .environment(networkState)
            .environment(batteryState)
            .environment(sensorState)
            .environment(fanState)
            .environment(profileState)
            .environment(AppSettings.shared)
            .environment(commands)
            .environment(powerState)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1050, height: 750),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Heimdall"
        window.contentViewController = NSHostingController(rootView: root)
        window.minSize = NSSize(width: 900, height: 650)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("HeimdallMain")
        window.center()

        mainWindowController = NSWindowController(window: window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshMainWindowVisibility()
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
        coordinator.processHistory = processHistory
        coordinator.powerState = powerState

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
            .environment(commands)

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
            // The timer fires on the main queue.
            MainActor.assumeIsolated { self?.statusBarController.updateWidget() }
        }
        displayTimer.resume()
        menuBarDisplayTimer = displayTimer
    }

    private func setupWindowVisibilityTracking() {
        let center = NotificationCenter.default

        let handler: @Sendable (Notification) -> Void = { [weak self] _ in
            guard let self else { return }
            // Deferred a turn so a closing window has actually gone before it is counted.
            DispatchQueue.main.async { self.refreshMainWindowVisibility() }
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
}
