import SwiftUI

struct GPUView: View {
    @Environment(GPUState.self) private var gpu
    @Environment(PowerState.self) private var power

    var body: some View {
        @Bindable var gpuBinding = gpu
        @Bindable var powerBinding = power
        ScrollView {
            VStack(spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("GPU").font(.largeTitle).fontWeight(.bold)
                        Text(gpu.usage.modelName).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal)

                HStack(spacing: 16) {
                    GaugeCard(title: "Utilization", percent: gpu.usage.utilization,
                              subtitle: String(format: "%.1f%%", gpu.usage.utilization),
                              icon: "square.3.layers.3d.top.filled", color: MetricColor.usage(gpu.usage.utilization))
                    GaugeCard(title: "Renderer", percent: gpu.usage.renderUtilization,
                              subtitle: String(format: "%.1f%%", gpu.usage.renderUtilization),
                              icon: "paintbrush.fill", color: MetricColor.usage(gpu.usage.renderUtilization))
                    GaugeCard(title: "Tiler", percent: gpu.usage.tilerUtilization,
                              subtitle: String(format: "%.1f%%", gpu.usage.tilerUtilization),
                              icon: "square.grid.3x3.fill", color: MetricColor.usage(gpu.usage.tilerUtilization))
                }
                .padding(.horizontal)

                // Usage history
                HistoryChartCard(
                    title: "Usage History",
                    range: $gpuBinding.historyRange,
                    series: [
                        .init(gpu.filteredHistory, value: { $0.utilization }, color: .blue, label: "Total"),
                        .init(gpu.filteredHistory, value: { $0.renderUtilization }, color: .green, label: "Renderer"),
                        .init(gpu.filteredHistory, value: { $0.tilerUtilization }, color: .orange, label: "Tiler"),
                    ],
                    yRange: 0...100,
                    yFormatter: { String(format: "%.0f%%", $0) },
                    tooltipFormatter: { String(format: "%.1f%%", $0) }
                )
                .padding(.horizontal)

                // SoC power from IOReport; hidden where it is unavailable.
                if power.latest != nil {
                    HistoryChartCard(
                        title: "Power History",
                        icon: "bolt.fill",
                        range: $powerBinding.historyRange,
                        series: [
                            .init(power.filteredHistory, value: { $0.cpu }, color: .blue, label: "CPU"),
                            .init(power.filteredHistory, value: { $0.gpu }, color: .green, label: "GPU"),
                            .init(power.filteredHistory, value: { $0.ane }, color: .purple, label: "Neural Engine"),
                        ],
                        yFormatter: { String(format: "%.1f W", $0) },
                        tooltipFormatter: { PowerFormatter.format($0) }
                    ) {
                        if let total = power.latest?.combined {
                            Text("SoC \(PowerFormatter.format(total))").font(.caption).foregroundStyle(.secondary)
                        }
                    } subheader: {
                        EmptyView()
                    }
                    .padding(.horizontal)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Details").font(.headline)
                    HStack { Text("Model").foregroundStyle(.secondary); Spacer(); Text(gpu.usage.modelName) }
                    Divider()
                    HStack { Text("Utilization").foregroundStyle(.secondary); Spacer(); Text(String(format: "%.1f%%", gpu.usage.utilization)) }
                    Divider()
                    HStack { Text("Renderer").foregroundStyle(.secondary); Spacer(); Text(String(format: "%.1f%%", gpu.usage.renderUtilization)) }
                    Divider()
                    HStack { Text("Tiler").foregroundStyle(.secondary); Spacer(); Text(String(format: "%.1f%%", gpu.usage.tilerUtilization)) }
                    if let soc = power.latest {
                        Divider()
                        HStack { Text("GPU power").foregroundStyle(.secondary); Spacer(); Text(soc.gpu.map(PowerFormatter.format) ?? "—") }
                        Divider()
                        HStack { Text("Neural Engine power").foregroundStyle(.secondary); Spacer(); Text(soc.neuralEngineIsIdle ? "Idle" : (soc.ane.map(PowerFormatter.format) ?? "—")) }
                    }
                }
                .font(.callout)
                .padding()
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                // Top GPU processes
                if !gpu.topProcesses.isEmpty {
                    ProcessListView(title: "Top GPU Processes", processes: gpu.topProcesses, processHistory: gpu.processHistory)
                        .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }


}
