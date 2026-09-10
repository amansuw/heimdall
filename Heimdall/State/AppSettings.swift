import Foundation
import ServiceManagement

/// What the status item shows next to (or instead of) the fan glyph.
enum MenuBarDisplay: String, CaseIterable, Identifiable, Sendable {
    case iconOnly
    case cpuTemperature
    case fanSpeed
    case cpuUsage

    var id: String { rawValue }

    var label: String {
        switch self {
        case .iconOnly:       return "Icon only"
        case .cpuTemperature: return "CPU temperature"
        case .fanSpeed:       return "Fan RPM"
        case .cpuUsage:       return "CPU usage"
        }
    }
}

enum TemperatureUnit: String, CaseIterable, Identifiable, Sendable {
    case celsius
    case fahrenheit

    var id: String { rawValue }
    var label: String { self == .celsius ? "Celsius (°C)" : "Fahrenheit (°F)" }
    var suffix: String { self == .celsius ? "°C" : "°F" }

    /// Sensors always report Celsius; conversion happens at the point of display.
    func convert(_ celsius: Double) -> Double {
        self == .celsius ? celsius : celsius * 9.0 / 5.0 + 32.0
    }

    /// Inverse of `convert`, for values the user types in their display unit.
    func toCelsius(_ value: Double) -> Double {
        self == .celsius ? value : (value - 32.0) * 5.0 / 9.0
    }
}

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let menuBarDisplay = "heimdall.menuBarDisplay"
        static let temperatureUnit = "heimdall.temperatureUnit"
        static let hasCompletedFirstRun = "heimdall.hasCompletedFirstRun"
    }

    /// The menu bar preference as last saved, readable off the main actor. The
    /// monitor's timer queues use it to pick their polling interval.
    nonisolated static var persistedMenuBarDisplay: MenuBarDisplay {
        MenuBarDisplay(rawValue: UserDefaults.standard.string(forKey: Key.menuBarDisplay) ?? "") ?? .iconOnly
    }

    var menuBarDisplay: MenuBarDisplay {
        didSet { UserDefaults.standard.set(menuBarDisplay.rawValue, forKey: Key.menuBarDisplay) }
    }

    var temperatureUnit: TemperatureUnit {
        didSet { UserDefaults.standard.set(temperatureUnit.rawValue, forKey: Key.temperatureUnit) }
    }

    var hasCompletedFirstRun: Bool {
        didSet { UserDefaults.standard.set(hasCompletedFirstRun, forKey: Key.hasCompletedFirstRun) }
    }

    /// Mirrors SMAppService so SwiftUI can bind to it. Registration can fail (for
    /// example when the app is not in /Applications), so the mirror is refreshed
    /// from the service rather than assumed to match.
    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            applyLaunchAtLogin()
        }
    }

    private(set) var launchAtLoginError: String?

    private init() {
        let defaults = UserDefaults.standard
        menuBarDisplay = MenuBarDisplay(rawValue: defaults.string(forKey: Key.menuBarDisplay) ?? "") ?? .iconOnly
        temperatureUnit = TemperatureUnit(rawValue: defaults.string(forKey: Key.temperatureUnit) ?? "") ?? .celsius
        hasCompletedFirstRun = defaults.bool(forKey: Key.hasCompletedFirstRun)
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
            // Put the toggle back where the system actually is.
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    func refreshLaunchAtLogin() {
        let enabled = SMAppService.mainApp.status == .enabled
        if launchAtLogin != enabled { launchAtLogin = enabled }
    }
}
