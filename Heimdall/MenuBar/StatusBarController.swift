import AppKit
import SwiftUI

class StatusBarController: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var eventMonitor: Any?
    private let fanIcon = MenuBarFanIcon()

    weak var cpuState: CPUState?
    weak var fanState: FanState?
    weak var sensorState: SensorState?
    weak var ramState: RAMState?
    weak var networkState: NetworkState?

    /// Called when the menu-bar popover opens/closes so polling can scale.
    var onPopoverVisibilityChanged: ((Bool) -> Void)?

    func setup(popoverContent: NSViewController) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem.button else { return }
        fanIcon.attach(to: button)

        button.action = #selector(togglePopover)
        button.target = self

        popover = NSPopover()
        popover.contentSize = NSSize(width: 380, height: 520)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = popoverContent

        updateWidget()
    }

    func updateWidget() {
        let loading = (sensorState?.isDiscovering ?? false) || (fanState?.isRequestingAccess ?? false)
        let cpuTemp = sensorState?.averageCPUTemp ?? 0
        fanIcon.update(cpuTempC: cpuTemp, loading: loading)
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            closePopover()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            onPopoverVisibilityChanged?(true)
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.closePopover()
            }
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        onPopoverVisibilityChanged?(false)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}
