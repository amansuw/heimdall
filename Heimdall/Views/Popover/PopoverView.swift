import SwiftUI

struct PopoverView: View {
    @Environment(CPUState.self) private var cpu
    @Environment(GPUState.self) private var gpu
    @Environment(RAMState.self) private var ram
    @Environment(SensorState.self) private var sensors
    @Environment(FanState.self) private var fan
    @Environment(NetworkState.self) private var network
    @Environment(BatteryState.self) private var battery
    @Environment(ProfileState.self) private var profileState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            // Temperature cards
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                MiniStatCard(label: "CPU Avg", value: sensors.averageCPUTemp, color: tempColor(sensors.averageCPUTemp))
                MiniStatCard(label: "GPU Avg", value: sensors.averageGPUTemp, color: tempColor(sensors.averageGPUTemp))
                MiniStatCard(label: "CPU Peak", value: sensors.hottestCPUTemp, color: tempColor(sensors.hottestCPUTemp))
                MiniStatCard(label: "GPU Peak", value: sensors.hottestGPUTemp, color: tempColor(sensors.hottestGPUTemp))
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)

            // Temperature chart
            VStack(spacing: 4) {
                let history = sensors.filteredHistory
                if history.count >= 2 {
                    CanvasMultiLineChart(series: [
                        .init(data: history.map(\.avgCPU), color: .blue, label: "CPU Avg"),
                        .init(data: history.map(\.maxCPU), color: .blue.opacity(0.5), label: "CPU Peak", dashed: true),
                        .init(data: history.map(\.avgGPU), color: .green, label: "GPU Avg"),
                        .init(data: history.map(\.maxGPU), color: .green.opacity(0.5), label: "GPU Peak", dashed: true),
                    ])
                    .frame(height: 100)
                    .padding(.horizontal, 10)
                }
            }
            .padding(.bottom, 6)

            Divider().padding(.horizontal, 8)

            // System stats row
            HStack(spacing: 6) {
                MiniGauge(label: "CPU", percent: cpu.usage.total, color: .blue)
                MiniGauge(label: "GPU", percent: gpu.usage.utilization, color: .green)
                MiniGauge(label: "RAM", percent: ram.memory.usagePercent, color: .purple)
                VStack(spacing: 1) {
                    Text("↓ " + ByteFormatter.formatSpeed(network.stats.downloadBytesPerSec))
                        .font(.system(size: 8, weight: .medium, design: .rounded)).foregroundStyle(.blue)
                    Text("↑ " + ByteFormatter.formatSpeed(network.stats.uploadBytesPerSec))
                        .font(.system(size: 8, weight: .medium, design: .rounded)).foregroundStyle(.green)
                    Text("Net").font(.system(size: 7)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)

            Divider().padding(.horizontal, 8)

            // Fan RPMs
            HStack(spacing: 0) {
                ForEach(fan.fans) { f in
                    HStack(spacing: 4) {
                        Image(systemName: "fan.fill").font(.system(size: 10)).foregroundStyle(.blue)
                        Text(f.name).font(.system(size: 10, weight: .medium))
                        Spacer()
                        Text(String(format: "%.0f", f.currentSpeed))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(f.isManual ? .orange : .primary)
                        Text("RPM").font(.system(size: 8)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)

            Divider().padding(.horizontal, 8)

            // Fan quick controls
            HStack(spacing: 4) {
                PopoverFanButton(label: "Auto", isActive: fan.unifiedSpeedLabel == "Auto") {
                    NotificationCenter.default.post(name: .fanSetAllAuto, object: nil)
                }
                PopoverFanButton(label: "25%", isActive: fan.unifiedSpeedLabel == "25%") {
                    NotificationCenter.default.post(name: .fanSetAllSpeed, object: 25.0)
                }
                PopoverFanButton(label: "50%", isActive: fan.unifiedSpeedLabel == "50%") {
                    NotificationCenter.default.post(name: .fanSetAllSpeed, object: 50.0)
                }
                PopoverFanButton(label: "75%", isActive: fan.unifiedSpeedLabel == "75%") {
                    NotificationCenter.default.post(name: .fanSetAllSpeed, object: 75.0)
                }
                PopoverFanButton(label: "Max", isActive: fan.unifiedSpeedLabel == "Max") {
                    NotificationCenter.default.post(name: .fanSetAllSpeed, object: 100.0)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)

            Divider().padding(.horizontal, 8)

            // Actions
            VStack(spacing: 0) {
                Button(action: {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }) {
                    HStack {
                        Text("Open Heimdall").font(.system(size: 12))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity).contentShape(Rectangle())
                    .padding(.vertical, 4).padding(.horizontal, 10)
                }
                .buttonStyle(.plain)

                Button(action: {
                    SMCKit.shared.resetAllFansToAutomatic()
                    NSApp.terminate(nil)
                }) {
                    HStack {
                        Text("Quit").font(.system(size: 12))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity).contentShape(Rectangle())
                    .padding(.vertical, 4).padding(.horizontal, 10)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 2)
        }
        .frame(width: 380)
    }

    private func tempColor(_ t: Double) -> Color {
        if t <= 0 { return .gray }; if t < 50 { return .green }; if t < 70 { return .yellow }; if t < 85 { return .orange }; return .red
    }
}

struct MiniStatCard: View {
    let label: String; let value: Double; let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "%.0f°C", value))
                .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(color)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct MiniGauge: View {
    let label: String; let percent: Double; let color: Color

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                CanvasGauge(percent: percent, color: color, lineWidth: 3)
                Text(String(format: "%.0f", percent))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
            }
            .frame(width: 32, height: 32)
            Text(label).font(.system(size: 7)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct PopoverFanButton: View {
    let label: String; let isActive: Bool; let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .frame(maxWidth: .infinity).padding(.vertical, 4)
                .background(isActive ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(isActive ? Color.accentColor : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
