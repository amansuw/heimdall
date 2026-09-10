import Foundation

// Fan control is driven through NotificationCenter so views can request changes
// without holding a reference to FanController. These names previously lived at
// the bottom of FanControlView.swift — a view that was never instantiated, yet
// could not be deleted because the entire app depended on this extension.
extension Notification.Name {
    static let requestFanAccess = Notification.Name("requestFanAccess")
    static let fanControlModeChanged = Notification.Name("fanControlModeChanged")
    static let fanSetAllAuto = Notification.Name("fanSetAllAuto")
    static let fanSetAllSpeed = Notification.Name("fanSetAllSpeed")
    static let fanApplyManual = Notification.Name("fanApplyManual")

    /// Asks AppDelegate to show the dashboard. The window is AppKit-owned, so
    /// views request it rather than opening it themselves.
    static let openMainWindow = Notification.Name("openMainWindow")
}
