import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case cpu = "CPU"
    case gpu = "GPU"
    case ram = "Memory"
    case disk = "Disk"
    case network = "Network"
    case battery = "Battery"
    case sensors = "Sensors"
    case fanSettings = "Fan Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.33percent"
        case .cpu: return "cpu"
        case .gpu: return "square.3.layers.3d.top.filled"
        case .ram: return "memorychip"
        case .disk: return "internaldrive"
        case .network: return "network"
        case .battery: return "battery.100percent"
        case .sensors: return "thermometer"
        case .fanSettings: return "fan.fill"
        }
    }
}

struct ContentView: View {
    @State private var selection: SidebarItem = .dashboard

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 250)
        } detail: {
            switch selection {
            case .dashboard: DashboardView()
            case .cpu: CPUView()
            case .gpu: GPUView()
            case .ram: RAMView()
            case .disk: DiskView()
            case .network: NetworkView()
            case .battery: BatteryView()
            case .sensors: SensorListView()
            case .fanSettings: FanSettingsView()
            }
        }
    }
}
