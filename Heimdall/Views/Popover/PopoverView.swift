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
    @Environment(AppCommands.self) private var commands

    var body: some View {
        VStack(spacing: 0) {
            // Temperature cards
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                MiniStatCard(label: "CPU Avg", value: sensors.averageCPUTemp, color: MetricColor.temperature(sensors.averageCPUTemp))
                MiniStatCard(label: "GPU Avg", value: sensors.averageGPUTemp, color: MetricColor.temperature(sensors.averageGPUTemp))
                MiniStatCard(label: "CPU Peak", value: sensors.hottestCPUTemp, color: MetricColor.temperature(sensors.hottestCPUTemp))
                MiniStatCard(label: "GPU Peak", value: sensors.hottestGPUTemp, color: MetricColor.temperature(sensors.hottestGPUTemp))
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)

            // Temperature chart
            VStack(spacing: 4) {
                let history = sensors.filteredHistory
                if history.count >= 2 {
                    CanvasMultiLineChart(series: [
                        .init(history, value: { $0.avgCPU }, color: .blue, label: "CPU Avg"),
                        .init(history, value: { $0.maxCPU }, color: .blue, label: "CPU Peak", dashed: true),
                        .init(history, value: { $0.avgGPU }, color: .green, label: "GPU Avg"),
                        .init(history, value: { $0.maxGPU }, color: .green, label: "GPU Peak", dashed: true),
                    ], window: sensors.historyRange.window,
                       yFormatter: { TempFormatter.axisLabel($0) },
                       tooltipFormatter: { TempFormatter.tooltipLabel($0) })
                    .frame(height: 100)
                    .padding(.horizontal, 10)
                }
            }
            .padding(.bottom, 6)

            Divider().padding(.horizontal, 8)

            // System stats row
            HStack(spacing: 6) {
                MiniGauge(label: "CPU", percent: cpu.usage.total, color: MetricColor.usage(cpu.usage.total))
                MiniGauge(label: "GPU", percent: gpu.usage.utilization, color: MetricColor.usage(gpu.usage.utilization))
                MiniGauge(label: "RAM", percent: ram.memory.usagePercent, color: MetricColor.usage(ram.memory.usagePercent))
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

            // Fan profiles
            HStack(spacing: 4) {
                ForEach(profileState.menuBarProfiles) { profile in
                    PopoverFanButton(
                        label: profile.name,
                        isActive: profileState.activeProfile?.id == profile.id
                    ) {
                        profileState.activate(profile, on: fan, commands: commands)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)

            Divider().padding(.horizontal, 8)

            // Actions
            VStack(spacing: 0) {
                Button(action: {
                    commands.openMainWindow()
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



}

struct MiniStatCard: View {
    let label: String; let value: Double; let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
            Text(TempFormatter.formatShort(value))
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
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity).padding(.vertical, 4)
                .background(isActive ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(isActive ? Color.accentColor : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
