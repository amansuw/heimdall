import Foundation
import Observation

/// What views may ask the app to do: change fan behaviour, request the helper,
/// open the dashboard.
///
/// These were NotificationCenter posts. Payloads travelled as `Any?`, so a speed
/// posted as an Int instead of a Double was dropped without a sound, and nothing
/// at a call site said who handled the request. Views now take this object from
/// the environment and call it.
@MainActor
@Observable
final class AppCommands {
    private let fanController: FanController
    private let coordinator: MonitorCoordinator
    private let showMainWindow: () -> Void

    init(fanController: FanController, coordinator: MonitorCoordinator, showMainWindow: @escaping () -> Void) {
        self.fanController = fanController
        self.coordinator = coordinator
        self.showMainWindow = showMainWindow
    }

    func requestFanAccess() {
        fanController.requestAdminAccess()
    }

    func openMainWindow() {
        showMainWindow()
    }

    // Every fan change is followed by a short burst of fast polling, so the UI
    // shows the fans responding rather than waiting for the next regular sample.

    func setControlMode(_ mode: FanControlMode) {
        fanController.setControlMode(mode)
        coordinator.boostFastPollingTemporarily()
    }

    func setAllFansAuto() {
        fanController.setAllFansAuto()
        coordinator.boostFastPollingTemporarily()
    }

    func setAllFansSpeed(_ percentage: Double) {
        fanController.setAllFansSpeed(percentage: percentage)
        coordinator.boostFastPollingTemporarily()
    }

    func applyManualSpeed() {
        fanController.applyManualSpeed()
        coordinator.boostFastPollingTemporarily()
    }
}
