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

    // Coordinator & controllers
    private let coordinator = MonitorCoordinator()
    private let fanController = FanController()
    private let statusBarController = StatusBarController()

    // Notification observers
    private var observers: [Any] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        profileState.loadProfiles()
        setupCoordinator()
        setupStatusBar()
        setupNotificationHandlers()
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
        statusBarController.setup(popoverContent: hostingController)

        // Update menu bar widget on a timer (separate from data polling)
        let displayTimer = DispatchSource.makeTimerSource(queue: .main)
        displayTimer.schedule(deadline: .now(), repeating: 2.0, leeway: .milliseconds(100))
        displayTimer.setEventHandler { [weak self] in
            self?.statusBarController.updateWidget()
        }
        displayTimer.resume()
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
