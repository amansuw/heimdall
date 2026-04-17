import SwiftUI

struct CPUView: View {
    @Environment(CPUState.self) private var cpu

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("CPU").font(.largeTitle).fontWeight(.bold)
                        Text("\(cpu.totalCores) cores (\(cpu.pCores) P + \(cpu.eCores) E)")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("Uptime: \(cpu.formattedUptime)").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                // Usage gauges
                HStack(spacing: 16) {
                    GaugeCard(title: "Total", percent: cpu.usage.total,
                              subtitle: String(format: "%.1f%%", cpu.usage.total),
                              icon: "cpu", color: usageColor(cpu.usage.total))
                    GaugeCard(title: "P-Cores", percent: cpu.usage.performanceCores,
                              subtitle: String(format: "%.1f%%", cpu.usage.performanceCores),
                              icon: "bolt.fill", color: usageColor(cpu.usage.performanceCores))
                    GaugeCard(title: "E-Cores", percent: cpu.usage.efficiencyCores,
                              subtitle: String(format: "%.1f%%", cpu.usage.efficiencyCores),
                              icon: "leaf.fill", color: usageColor(cpu.usage.efficiencyCores))
                }
                .padding(.horizontal)

                // Per-core bars - P-Cores
                let pCores = cpu.usage.perCore.filter { !$0.isEfficiency }
                let eCores = cpu.usage.perCore.filter { $0.isEfficiency }

                if !pCores.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("P-Core Usage").font(.headline)
                            Spacer()
                            Text("\(pCores.count) cores").font(.caption).foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: min(pCores.count, 8)), spacing: 4) {
                            ForEach(pCores) { core in
                                VStack(spacing: 2) {
                                    GeometryReader { geo in
                                        let height = geo.size.height * CGFloat(min(core.usage / 100, 1))
                                        VStack {
                                            Spacer()
                                            Rectangle()
                                                .fill(Color.blue)
                                                .frame(height: height)
                                        }
                                    }
                                    .frame(height: 40)
                                    .background(Color.secondary.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 2))
                                    Text("\(core.id)").font(.system(size: 7)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                }

                // Per-core bars - E-Cores
                if !eCores.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("E-Core Usage").font(.headline)
                            Spacer()
                            Text("\(eCores.count) cores").font(.caption).foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: min(eCores.count, 8)), spacing: 4) {
                            ForEach(eCores) { core in
                                VStack(spacing: 2) {
                                    GeometryReader { geo in
                                        let height = geo.size.height * CGFloat(min(core.usage / 100, 1))
                                        VStack {
                                            Spacer()
                                            Rectangle()
                                                .fill(Color.green)
                                                .frame(height: height)
                                        }
                                    }
                                    .frame(height: 40)
                                    .background(Color.secondary.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 2))
                                    Text("\(core.id)").font(.system(size: 7)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                }

                // Usage history
                VStack(alignment: .leading, spacing: 8) {
                    Text("Usage History").font(.headline)
                    @Bindable var cpuBinding = cpu
                    HStack(spacing: 6) {
                        Text("Range")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Range", selection: $cpuBinding.historyRange) {
                            ForEach(HistoryRange.allCases) { range in
                                Text(range.rawValue).tag(range)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    let historyArray = cpu.filteredHistory
                    if historyArray.count >= 2 {
                        CanvasMultiLineChart(series: [
                            .init(data: historyArray.map(\.total), color: .blue, label: "Total"),
                            .init(data: historyArray.map(\.user), color: .green, label: "User"),
                            .init(data: historyArray.map(\.system), color: .orange, label: "System"),
                        ], yRange: 0...100)
                        .frame(height: 150)
                        HStack(spacing: 16) {
                            legendDot(color: .blue, label: "Total")
                            legendDot(color: .green, label: "User")
                            legendDot(color: .orange, label: "System")
                        }.font(.caption2)
                    } else {
                        ProgressView().frame(height: 100)
                    }
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                // Load averages + Frequency
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Load Average").font(.headline)
                        HStack {
                            VStack { Text("1m").font(.caption2).foregroundStyle(.secondary); Text(String(format: "%.2f", cpu.loadAverage.oneMinute)).font(.callout).fontDesign(.rounded) }
                            Spacer()
                            VStack { Text("5m").font(.caption2).foregroundStyle(.secondary); Text(String(format: "%.2f", cpu.loadAverage.fiveMinute)).font(.callout).fontDesign(.rounded) }
                            Spacer()
                            VStack { Text("15m").font(.caption2).foregroundStyle(.secondary); Text(String(format: "%.2f", cpu.loadAverage.fifteenMinute)).font(.callout).fontDesign(.rounded) }
                        }
                    }
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Frequency").font(.headline)
                        HStack {
                            VStack { Text("All").font(.caption2).foregroundStyle(.secondary); Text("\(cpu.frequency.allCores) MHz").font(.callout).fontDesign(.rounded) }
                            Spacer()
                            VStack { Text("P-Cores").font(.caption2).foregroundStyle(.secondary); Text("\(cpu.frequency.performanceCores) MHz").font(.callout).fontDesign(.rounded) }
                            Spacer()
                            VStack { Text("E-Cores").font(.caption2).foregroundStyle(.secondary); Text("\(cpu.frequency.efficiencyCores) MHz").font(.callout).fontDesign(.rounded) }
                        }
                    }
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal)

                // Top processes
                ProcessListView(title: "Top CPU Processes", processes: cpu.topProcesses)
                    .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func usageColor(_ v: Double) -> Color {
        if v < 30 { return .green }; if v < 60 { return .yellow }; if v < 80 { return .orange }; return .red
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) { Circle().fill(color).frame(width: 6, height: 6); Text(label).foregroundStyle(.secondary) }
    }
}

struct ProcessListView: View {
    let title: String
    let processes: [TopProcess]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if processes.isEmpty {
                Text("No data").font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                ForEach(processes) { proc in
                    HStack {
                        Text(proc.name).font(.callout).lineLimit(1)
                        Spacer()
                        Text(proc.formattedValue).font(.callout).fontWeight(.medium).fontDesign(.rounded)
                    }
                    if proc.id != processes.last?.id { Divider() }
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}
