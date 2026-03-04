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

    var body: some View {
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
                              icon: "cpu", color: gaugeColor(cpu.usage.total))
                    GaugeCard(title: "GPU", percent: gpu.usage.utilization,
                              subtitle: gpu.usage.modelName,
                              icon: "square.3.layers.3d.top.filled", color: gaugeColor(gpu.usage.utilization))
                    GaugeCard(title: "RAM", percent: ram.memory.usagePercent,
                              subtitle: "\(ByteFormatter.format(ram.memory.used)) / \(ByteFormatter.format(ram.memory.total))",
                              icon: "memorychip", color: ramColor(ram.memory.usagePercent))
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
                                 icon: "internaldrive", color: d.usagePercent > 90 ? .red : d.usagePercent > 75 ? .orange : .blue)
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
                    StatCard(title: "Avg CPU (\(sensors.cpuCoreCount))", value: TempFormatter.format(sensors.averageCPUTemp),
                             icon: "cpu", color: tempColor(sensors.averageCPUTemp))
                    StatCard(title: "Peak CPU", value: TempFormatter.format(sensors.hottestCPUTemp),
                             icon: "flame", color: tempColor(sensors.hottestCPUTemp))
                    StatCard(title: "Avg GPU (\(sensors.gpuCoreCount))", value: TempFormatter.format(sensors.averageGPUTemp),
                             icon: "square.3.layers.3d.top.filled", color: tempColor(sensors.averageGPUTemp))
                    StatCard(title: "Peak GPU", value: TempFormatter.format(sensors.hottestGPUTemp),
                             icon: "flame.fill", color: tempColor(sensors.hottestGPUTemp))
                }
                .padding(.horizontal)

                // Temperature history chart
                VStack(alignment: .leading, spacing: 8) {
                    @Bindable var sensorBinding = sensors
                    HStack(spacing: 6) {
                        Text("Range")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Range", selection: $sensorBinding.historyRange) {
                            ForEach(HistoryRange.allCases) { range in
                                Text(range.rawValue).tag(range)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    DashboardTempChart(history: sensors.filteredHistory)
                }
                .padding(.horizontal)

                // Fan status + Quick presets
                DashboardFanCard()
                    .padding(.horizontal)

                // Fan Quick Presets
                if fan.hasWriteAccess {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Fan Quick Presets").font(.headline)
                        HStack(spacing: 8) {
                            dashPresetButton("Auto", isActive: fan.unifiedSpeedLabel == "Auto") {
                                NotificationCenter.default.post(name: .fanSetAllAuto, object: nil)
                            }
                            dashPresetButton("25%", isActive: fan.unifiedSpeedLabel == "25%") {
                                NotificationCenter.default.post(name: .fanSetAllSpeed, object: 25.0)
                            }
                            dashPresetButton("50%", isActive: fan.unifiedSpeedLabel == "50%") {
                                NotificationCenter.default.post(name: .fanSetAllSpeed, object: 50.0)
                            }
                            dashPresetButton("75%", isActive: fan.unifiedSpeedLabel == "75%") {
                                NotificationCenter.default.post(name: .fanSetAllSpeed, object: 75.0)
                            }
                            dashPresetButton("Max", isActive: fan.unifiedSpeedLabel == "Max") {
                                NotificationCenter.default.post(name: .fanSetAllSpeed, object: 100.0)
                            }
                        }

                        // Latest saved fan curve profile
                        if let latest = profileState.latestCustomProfile {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Latest Profile").font(.caption2).foregroundStyle(.secondary)
                                    Text(latest.name).font(.caption).fontWeight(.medium)
                                }
                                Spacer()
                                if let c = latest.curve {
                                    DashboardCurvePreview(curve: c)
                                        .frame(width: 80, height: 30)
                                }
                                Button("Activate") {
                                    profileState.setActiveProfile(latest)
                                    if let c = latest.curve {
                                        fan.activeCurve = c
                                        NotificationCenter.default.post(name: .fanControlModeChanged, object: FanControlMode.curve)
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.mini)
                                .disabled(profileState.activeProfile?.id == latest.id)
                            }
                            .padding(8)
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

    private func gaugeColor(_ v: Double) -> Color {
        if v < 30 { return .green }; if v < 60 { return .yellow }; if v < 80 { return .orange }; return .red
    }
    private func ramColor(_ v: Double) -> Color {
        if v < 50 { return .green }; if v < 75 { return .yellow }; if v < 90 { return .orange }; return .red
    }
    private func tempColor(_ t: Double) -> Color {
        if t <= 0 { return .gray }; if t < 45 { return .green }; if t < 65 { return .yellow }; if t < 80 { return .orange }; return .red
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

struct DashboardCurvePreview: View {
    let curve: FanCurve

    var body: some View {
        Canvas { context, size in
            let sorted = curve.sortedPoints
            guard sorted.count >= 2 else { return }

            var path = Path()
            for (i, point) in sorted.enumerated() {
                let x = ((point.temperature - 20) / 90) * size.width
                let y = size.height - (CGFloat(point.fanSpeed) / 100.0) * size.height
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }

            var fillPath = path
            if let last = sorted.last {
                fillPath.addLine(to: CGPoint(x: ((last.temperature - 20) / 90) * size.width, y: size.height))
            }
            if let first = sorted.first {
                fillPath.addLine(to: CGPoint(x: ((first.temperature - 20) / 90) * size.width, y: size.height))
            }
            fillPath.closeSubpath()
            context.fill(fillPath, with: .color(.blue.opacity(0.15)))
            context.stroke(path, with: .color(.blue.opacity(0.7)), lineWidth: 1)
        }
        .background(Color.secondary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 4))
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

struct DashboardTempChart: View {
    let history: [TemperatureSnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "chart.xyaxis.line").foregroundStyle(.blue)
                Text("Temperature History").font(.headline)
                Spacer()
                if let last = history.last {
                    Text("CPU \(String(format: "%.0f", last.avgCPU))° · GPU \(String(format: "%.0f", last.avgGPU))°")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if history.count >= 2 {
                CanvasMultiLineChart(series: [
                    .init(data: history.map(\.avgCPU), color: .blue, label: "CPU Avg"),
                    .init(data: history.map(\.maxCPU), color: .blue.opacity(0.5), label: "CPU Peak", dashed: true),
                    .init(data: history.map(\.avgGPU), color: .green, label: "GPU Avg"),
                    .init(data: history.map(\.maxGPU), color: .green.opacity(0.5), label: "GPU Peak", dashed: true),
                ])
                .frame(height: 180)
            } else {
                HStack { Spacer(); ProgressView(); Text("Collecting data...").font(.caption).foregroundStyle(.secondary); Spacer() }
                    .padding(.vertical, 30)
            }

            HStack(spacing: 16) {
                legendDot(color: .blue, label: "CPU Avg")
                legendDot(color: .blue.opacity(0.5), label: "CPU Peak")
                legendDot(color: .green, label: "GPU Avg")
                legendDot(color: .green.opacity(0.5), label: "GPU Peak")
            }
            .font(.caption2)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).foregroundStyle(.secondary)
        }
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
