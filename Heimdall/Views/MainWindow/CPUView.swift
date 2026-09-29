import SwiftUI

struct CPUView: View {
    @Environment(CPUState.self) private var cpu

    var body: some View {
        @Bindable var cpuBinding = cpu
        ScrollView {
            VStack(spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("CPU").font(.largeTitle).fontWeight(.bold)
                        Text(cpu.topologyDescription)
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
                              icon: "cpu", color: MetricColor.usage(cpu.usage.total))
                    ForEach(cpu.usage.clusters) { cluster in
                        GaugeCard(title: cluster.name, percent: cluster.usage,
                                  subtitle: String(format: "%.1f%%", cluster.usage),
                                  icon: clusterIcon(cluster), color: MetricColor.usage(cluster.usage))
                    }
                }
                .padding(.horizontal)

                // Per-core bars, efficiency first, then the rest in hardware order.
                ForEach(coreSections) { cluster in
                    let cores = cpu.usage.perCore.filter { $0.clusterID == cluster.id }
                    if !cores.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("\(cluster.name) Usage").font(.headline)
                                Spacer()
                                Text("\(cores.count) cores").font(.caption).foregroundStyle(.secondary)
                            }
                            // Performance wraps at 5 so a 10-core cluster is two full rows.
                            // A short row stretches to the full width instead of leaving empty slots.
                            CoreUsageRows(
                                cores: cores.map { CoreBar(id: $0.id, usage: $0.usage) },
                                color: clusterColor(cluster),
                                perRow: cluster.letter == "P" ? 5 : 10
                            )
                        }
                        .padding()
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                    }
                }

                // Usage history
                HistoryChartCard(
                    title: "Usage History",
                    range: $cpuBinding.historyRange,
                    series: [
                        .init(cpu.filteredHistory, value: { $0.total }, color: .blue, label: "Total"),
                        .init(cpu.filteredHistory, value: { $0.user }, color: .green, label: "User"),
                        .init(cpu.filteredHistory, value: { $0.system }, color: .orange, label: "System"),
                    ],
                    yRange: 0...100,
                    yFormatter: { String(format: "%.0f%%", $0) },
                    tooltipFormatter: { String(format: "%.1f%%", $0) }
                )
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

                    // Only shown for chips with a known ceiling; otherwise the numbers
                    // would be invented rather than merely approximate.
                    if cpu.frequency.isEstimated {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 4) {
                                Text("Frequency").font(.headline)
                                Text("estimated").font(.caption2).foregroundStyle(.secondary)
                                    .help("Derived from load against this chip's rated maximum. macOS does not expose measured clocks.")
                            }
                            HStack {
                                VStack { Text("All").font(.caption2).foregroundStyle(.secondary); Text("\(cpu.frequency.allCores) MHz").font(.callout).fontDesign(.rounded) }
                                ForEach(cpu.usage.clusters) { cluster in
                                    if let mhz = cpu.frequency.perCluster[cluster.id] {
                                        Spacer()
                                        VStack { Text(cluster.name).font(.caption2).foregroundStyle(.secondary); Text("\(mhz) MHz").font(.callout).fontDesign(.rounded) }
                                    }
                                }
                            }
                        }
                        .padding()
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(.horizontal)

                // Top processes
                ProcessListView(title: "Top CPU Processes", processes: cpu.topProcesses, processHistory: cpu.processHistory)
                    .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }


    /// Efficiency cores lead the per-core sections. Everything else keeps
    /// the hardware order (performance first among the remainder).
    private var coreSections: [CPUCluster] {
        let clusters = cpu.usage.clusters
        return clusters.filter { $0.letter == "E" } + clusters.filter { $0.letter != "E" }
    }

    /// Cluster colours/icons are assigned by position, so a third cluster type
    /// renders sensibly without needing to know what it is.
    private func clusterColor(_ cluster: CPUCluster) -> Color {
        let palette: [Color] = [.blue, .green, .purple, .orange]
        return palette[cluster.id % palette.count]
    }

    private func clusterIcon(_ cluster: CPUCluster) -> String {
        switch cluster.letter {
        case "P": return "bolt.fill"
        case "E": return "leaf.fill"
        default:  return "cpu"
        }
    }

}

struct CoreBar: Identifiable {
    let id: Int
    let usage: Double
}

/// Rows of core bars. A row with fewer bars than `perRow` stretches those bars
/// across the full width, so a leftover 2 or 3 does not sit beside empty slots.
struct CoreUsageRows: View {
    let cores: [CoreBar]
    let color: Color
    var perRow: Int = 5
    var barHeight: CGFloat = 72

    var body: some View {
        VStack(spacing: 10) {
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    ForEach(row.cores) { core in
                        CoreUsageBar(id: core.id, usage: core.usage, color: color, barHeight: barHeight)
                    }
                }
            }
        }
    }

    private var rows: [CoreRow] {
        let width = max(perRow, 1)
        return stride(from: 0, to: cores.count, by: width).map { start in
            CoreRow(id: start, cores: Array(cores[start..<min(start + width, cores.count)]))
        }
    }

    private struct CoreRow: Identifiable {
        let id: Int
        let cores: [CoreBar]
    }
}

/// Single core usage bar with hover percentage.
struct CoreUsageBar: View {
    let id: Int
    let usage: Double
    let color: Color
    var barHeight: CGFloat = 40

    @State private var isHovering = false

    var body: some View {
        GeometryReader { geo in
            let fillHeight = geo.size.height * CGFloat(min(max(usage / 100, 0), 1))
            ZStack(alignment: .bottom) {
                Color.clear
                Rectangle()
                    .fill(color)
                    .frame(height: fillHeight)
                if isHovering {
                    Text(String(format: "%.1f%%", usage))
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 3)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 3))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(2)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: barHeight)
        .frame(maxWidth: .infinity)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active:
                isHovering = true
            case .ended:
                isHovering = false
            }
        }
        .help(String(format: "Core %d: %.1f%%", id, usage))
    }
}

struct ProcessListView: View {
    let title: String
    let processes: [TopProcess]
    var processHistory: ProcessHistory?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if processes.isEmpty {
                Text("No data").font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                ForEach(processes) { proc in
                    HStack(spacing: 8) {
                        if proc.canTerminate {
                            Button {
                                processHistory?.markTerminated(pid: proc.pid, name: proc.name)
                                ProcessTerminator.terminate(pid: proc.pid)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16, height: 16)
                                    .background(Color.secondary.opacity(0.15), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .help("Quit \(proc.name)")
                        } else {
                            Color.clear.frame(width: 16, height: 16)
                        }
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
