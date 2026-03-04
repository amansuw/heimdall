import AppKit
import SwiftUI

class StatusBarController {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var eventMonitor: Any?
    private var widgetView: MenuBarWidgetView?

    // State references for widget updates
    weak var cpuState: CPUState?
    weak var fanState: FanState?
    weak var sensorState: SensorState?
    weak var ramState: RAMState?
    weak var networkState: NetworkState?

    func setup(popoverContent: NSViewController) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.length = max(NSStatusItem.squareLength, 28)

        guard let button = statusItem.button else { return }

        // Pure AppKit: layer-backed widget view for GPU-accelerated rendering
        let widget = MenuBarWidgetView(frame: button.bounds)
        widget.autoresizingMask = [.width, .height]
        button.addSubview(widget)
        self.widgetView = widget

        button.action = #selector(togglePopover)
        button.target = self

        popover = NSPopover()
        popover.contentSize = NSSize(width: 380, height: 520)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = popoverContent
    }

    func updateWidget() {
        guard let widget = widgetView else { return }

        let isLoading = (sensorState?.isDiscovering ?? false) || (fanState?.isRequestingAccess ?? false)
        widget.setLoading(isLoading)
        if isLoading { return }

        let fanPct = fanState?.averageSpeedPercentage ?? 0
        let cpuTemp = sensorState?.averageCPUTemp ?? 0

        let color: NSColor
        if fanPct <= 0 { color = .systemGray }
        else if fanPct < 20 { color = .systemBlue }
        else if fanPct < 40 { color = .systemGreen }
        else if fanPct < 60 { color = .systemYellow }
        else if fanPct < 80 { color = .systemOrange }
        else { color = .systemRed }

        widget.updateFanIcon(color: color, rotation: fanPct * 3.6)
        widget.updateTempText(temp: cpuTemp)
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            closePopover()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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
}
