import SwiftUI

struct DashboardView: View {
    @Environment(CPUState.self) private var cpu
    @Environment(GPUState.self) private var gpu
    @Environment(RAMState.self) private var ram
    @Environment(SensorState.self) private var sensors
    @Environment(FanState.self) private var fan
    @Environment(ProfileState.self) private var profileState
    @Environment(NetworkState.self) private var network
    @Environment(DiskState.self) private var disk
    @Environment(BatteryState.self) private var battery
    @Environment(AppCommands.self) private var commands
    @Environment(PowerState.self) private var power

    var body: some View {
        @Bindable var sensorBinding = sensors
        @Bindable var powerBinding = power
        ScrollView {
            VStack(spacing: 20) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Dashboard")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        Text("\(sensors.readings.count) sensors · \(fan.fans.count) fans")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal)

                // System Stats Overview
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    GaugeCard(title: "CPU", percent: cpu.usage.total,
                              subtitle: String(format: "%.0f%% User · %.0f%% Sys", cpu.usage.user, cpu.usage.system),
                              icon: "cpu", color: MetricColor.usage(cpu.usage.total))
                    GaugeCard(title: "GPU", percent: gpu.usage.utilization,
                              subtitle: gpu.usage.modelName,
                              icon: "square.3.layers.3d.top.filled", color: MetricColor.usage(gpu.usage.utilization))
                    GaugeCard(title: "RAM", percent: ram.memory.usagePercent,
                              subtitle: "\(ByteFormatter.format(ram.memory.used)) / \(ByteFormatter.format(ram.memory.total))",
                              icon: "memorychip", color: MetricColor.usage(ram.memory.usagePercent))
                }
                .padding(.horizontal)

                // Network + Disk row
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    StatCard(title: "Network ↓", value: ByteFormatter.formatSpeed(network.stats.downloadBytesPerSec),
                             icon: "arrow.down.circle.fill", color: .blue)
                    StatCard(title: "Network ↑", value: ByteFormatter.formatSpeed(network.stats.uploadBytesPerSec),
                             icon: "arrow.up.circle.fill", color: .green)
                    if let d = disk.disks.first {
                        StatCard(title: "Disk", value: String(format: "%.0f%% used", d.usagePercent),
                                 icon: "internaldrive", color: MetricColor.usage(d.usagePercent))
                    } else {
                        StatCard(title: "Disk", value: "N/A", icon: "internaldrive", color: .gray)
                    }
                }
                .padding(.horizontal)

                // Battery row
                if battery.battery.hasBattery {
                    HStack(spacing: 12) {
                        StatCard(title: "Battery", value: String(format: "%.0f%%", battery.battery.level),
                                 icon: battery.battery.isCharging ? "battery.100percent.bolt" : "battery.100percent",
                                 color: battery.battery.level > 20 ? .green : .red)
                        StatCard(title: "Health", value: String(format: "%.0f%%", battery.battery.healthPercent),
                                 icon: "heart.fill", color: battery.battery.healthPercent > 80 ? .green : .yellow)
                    }
                    .padding(.horizontal)
                }

                // Temperature cards
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                    StatCard(title: sensorCardTitle("Avg CPU", sensors.cpuSensorCount), value: TempFormatter.format(sensors.averageCPUTemp),
                             icon: "cpu", color: MetricColor.temperature(sensors.averageCPUTemp))
                    StatCard(title: "Peak CPU", value: TempFormatter.format(sensors.hottestCPUTemp),
                             icon: "flame", color: MetricColor.temperature(sensors.hottestCPUTemp))
                    StatCard(title: sensorCardTitle("Avg GPU", sensors.gpuSensorCount), value: TempFormatter.format(sensors.averageGPUTemp),
                             icon: "square.3.layers.3d.top.filled", color: MetricColor.temperature(sensors.averageGPUTemp))
                    StatCard(title: "Peak GPU", value: TempFormatter.format(sensors.hottestGPUTemp),
                             icon: "flame.fill", color: MetricColor.temperature(sensors.hottestGPUTemp))
                }
                .padding(.horizontal)

                // Temperature history chart
                HistoryChartCard(
                    title: "Temperature History",
                    icon: "chart.xyaxis.line",
                    range: $sensorBinding.historyRange,
                    series: [
                        .init(sensors.filteredHistory, value: { $0.avgCPU }, color: .blue, label: "CPU Avg"),
                        .init(sensors.filteredHistory, value: { $0.maxCPU }, color: .blue, label: "CPU Peak", dashed: true),
                        .init(sensors.filteredHistory, value: { $0.avgGPU }, color: .green, label: "GPU Avg"),
                        .init(sensors.filteredHistory, value: { $0.maxGPU }, color: .green, label: "GPU Peak", dashed: true),
                    ],
                    yFormatter: { TempFormatter.axisLabel($0) },
                    tooltipFormatter: { TempFormatter.tooltipLabel($0) }
                ) {
                    if let last = sensors.filteredHistory.last {
                        Text("CPU \(tempText(last.avgCPU)) · GPU \(tempText(last.avgGPU))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } subheader: {
                    EmptyView()
                }
                .padding(.horizontal)

                // SoC power from IOReport; hidden where it is unavailable.
                if let soc = power.latest {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                        StatCard(title: "CPU Power", value: powerText(soc.cpu), icon: "cpu", color: .blue)
                        StatCard(title: "GPU Power", value: powerText(soc.gpu),
                                 icon: "square.3.layers.3d.top.filled", color: .green)
                        StatCard(title: "SoC Total", value: powerText(soc.combined), icon: "sum", color: .indigo)
                        StatCard(title: "System", value: powerText(soc.system), icon: "bolt.fill", color: .orange)
                    }
                    .padding(.horizontal)

                    HistoryChartCard(
                        title: "Power History",
                        icon: "bolt.fill",
                        range: $powerBinding.historyRange,
                        series: [
                            .init(power.filteredHistory, value: { $0.cpu }, color: .blue, label: "CPU"),
                            .init(power.filteredHistory, value: { $0.gpu }, color: .green, label: "GPU"),
                            .init(power.filteredHistory, value: { $0.system }, color: .orange, label: "System", dashed: true),
                        ],
                        yFormatter: { String(format: "%.1f W", $0) },
                        tooltipFormatter: { PowerFormatter.format($0) }
                    ) {
                        EmptyView()
                    } subheader: {
                        if soc.cpu == nil {
                            Text(fan.hasWriteAccess
                                 ? "Waiting for macOS to publish CPU energy…"
                                 : "macOS publishes CPU energy only to a privileged sampler. Enable Fan Control in Settings to install Heimdall's helper, which turns it on.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal)
                }

                // Fan status + Quick presets
                DashboardFanCard()
                    .padding(.horizontal)

                // Fan Quick Presets
                if fan.hasWriteAccess {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Fan Quick Presets").font(.headline)
                        HStack(spacing: 8) {
                            dashPresetButton("Auto", isActive: fan.unifiedSpeedLabel == "Auto") {
                                commands.setAllFansAuto()
                            }
                            dashPresetButton("25%", isActive: fan.unifiedSpeedLabel == "25%") {
                                commands.setAllFansSpeed(25)
                            }
                            dashPresetButton("50%", isActive: fan.unifiedSpeedLabel == "50%") {
                                commands.setAllFansSpeed(50)
                            }
                            dashPresetButton("75%", isActive: fan.unifiedSpeedLabel == "75%") {
                                commands.setAllFansSpeed(75)
                            }
                            dashPresetButton("Max", isActive: fan.unifiedSpeedLabel == "Max") {
                                commands.setAllFansSpeed(100)
                            }
                        }

                        // Latest saved fan curve profile
                        if let latest = profileState.latestCustomProfile {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Latest Profile").font(.caption2).foregroundStyle(.secondary)
                                    Text(latest.name).font(.caption).fontWeight(.medium)
                                }
                                .frame(minWidth: 72, alignment: .leading)

                                if let c = latest.curve {
                                    FanCurvePreview(curve: c)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 48)
                                        .background(Color.secondary.opacity(0.06))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                } else {
                                    Spacer(minLength: 0)
                                }

                                Button("Activate") {
                                    profileState.activate(latest, on: fan, commands: commands)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.mini)
                                .disabled(profileState.activeProfile?.id == latest.id)
                            }
                            .padding(10)
                            .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                }

                // Sensor groups
                HStack(alignment: .top, spacing: 12) {
                    SensorGroupCard(title: "CPU Temperatures", icon: "cpu", readings: sensors.dashboardCPUTemps)
                    SensorGroupCard(title: "GPU Temperatures", icon: "square.3.layers.3d.top.filled", readings: sensors.dashboardGPUTemps)
                }
                .padding(.horizontal)

                if !sensors.dashboardSystemTemps.isEmpty {
                    SensorGroupCard(title: "System", icon: "laptopcomputer", readings: sensors.dashboardSystemTemps)
                        .padding(.horizontal)
                }

                if !sensors.powerReadings.isEmpty {
                    SensorGroupCard(title: "Power", icon: "bolt.fill", readings: Array(sensors.powerReadings.prefix(10)))
                        .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }


    /// The count is temperature sensors averaged, not cores: an M3 Max has 4
    /// CPU-die sensors for 14 cores.
    private func sensorCardTitle(_ title: String, _ count: Int) -> String {
        switch count {
        case 0: return title
        case 1: return "\(title) · 1 sensor"
        default: return "\(title) · \(count) sensors"
        }
    }

    private func powerText(_ watts: Double?) -> String {
        watts.map(PowerFormatter.format) ?? "—"
    }

    /// A missing reading renders as an em dash rather than a misleading 0.
    private func tempText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return TempFormatter.formatShort(value)
    }

    private func dashPresetButton(_ label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption).fontWeight(.medium)
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .background(isActive ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(isActive ? Color.accentColor : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(fan.isYielding)
    }
}

// MARK: - Dashboard Components

struct GaugeCard: View {
    let title: String; let percent: Double; let subtitle: String; let icon: String; let color: Color

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                CanvasGauge(percent: percent, color: color)
                VStack(spacing: 1) {
                    Text(String(format: "%.0f%%", percent))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Image(systemName: icon)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 64)
            Text(title).font(.caption).fontWeight(.medium)
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct StatCard: View {
    let title: String; let value: String; let icon: String; let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon).font(.caption).foregroundStyle(color)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.title2).fontWeight(.semibold).fontDesign(.rounded).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct DashboardFanCard: View {
    @Environment(FanState.self) private var fan

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                ForEach(fan.fans) { f in
                    HStack(spacing: 8) {
                        Image(systemName: "fan.fill").font(.title3).foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.name).font(.subheadline).fontWeight(.medium)
                            Text(f.isManual ? "Manual" : "Automatic").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(String(format: "%.0f", f.currentSpeed)).font(.title3).fontWeight(.bold).fontDesign(.rounded)
                            Text("RPM").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                if fan.fans.isEmpty {
                    HStack {
                        Image(systemName: "fan.slash").foregroundStyle(.secondary)
                        Text("No fans detected").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct SensorGroupCard: View {
    let title: String; let icon: String; let readings: [SensorReading]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon).foregroundStyle(.blue)
                Text(title).font(.headline)
                Spacer()
                Text("\(readings.count)").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }.padding(.bottom, 4)

            if readings.isEmpty {
                Text("No sensors available").font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                ForEach(readings) { reading in
                    HStack {
                        Text(reading.name).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Text(reading.formattedValue).font(.callout).fontWeight(.medium).fontDesign(.rounded)
                    }
                    if reading.id != readings.last?.id { Divider() }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}
