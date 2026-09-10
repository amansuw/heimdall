import Foundation
import Sparkle

/// In-app updates through Sparkle.
///
/// Heimdall is not notarized, so a freshly downloaded DMG has to be approved in
/// Privacy & Security before it will open. Sparkle installs updates itself, which
/// spares users that approval on every release. Each update is verified against the
/// EdDSA public key built into the app before it is installed.
///
/// Builds without a key — anything built from source — never start the updater.
@MainActor
@Observable
final class UpdaterModel {
    /// nil when this build is not configured for updates.
    private let controller: SPUStandardUpdaterController?

    var isAvailable: Bool { controller != nil }

    var automaticallyChecksForUpdates: Bool {
        didSet {
            guard automaticallyChecksForUpdates != oldValue else { return }
            controller?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    init() {
        if UpdateConfiguration.current != nil {
            let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            self.controller = controller
            automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        } else {
            controller = nil
            automaticallyChecksForUpdates = false
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
