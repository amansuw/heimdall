import SwiftUI

struct GPUView: View {
    @Environment(GPUState.self) private var gpu

    var body: some View {
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
                VStack(alignment: .leading, spacing: 8) {
                    Text("Usage History").font(.headline)
                    @Bindable var gpuBinding = gpu
                    HStack(spacing: 6) {
                        Text("Range")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Range", selection: $gpuBinding.historyRange) {
                            ForEach(HistoryRange.allCases) { range in
                                Text(range.rawValue).tag(range)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    let historyArray = gpu.filteredHistory
                    if historyArray.count >= 2 {
                        CanvasMultiLineChart(series: [
                            .init(historyArray, value: { $0.utilization }, color: .blue, label: "Total"),
                            .init(historyArray, value: { $0.renderUtilization }, color: .green, label: "Renderer"),
                            .init(historyArray, value: { $0.tilerUtilization }, color: .orange, label: "Tiler"),
                        ], window: gpu.historyRange.window, yRange: 0...100)
                        .frame(height: 150)
                        HStack(spacing: 16) {
                            legendDot(color: .blue, label: "Total")
                            legendDot(color: .green, label: "Renderer")
                            legendDot(color: .orange, label: "Tiler")
                        }.font(.caption2)
                    } else {
                        ProgressView().frame(height: 100)
                    }
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Details").font(.headline)
                    HStack { Text("Model").foregroundStyle(.secondary); Spacer(); Text(gpu.usage.modelName) }
                    Divider()
                    HStack { Text("Utilization").foregroundStyle(.secondary); Spacer(); Text(String(format: "%.1f%%", gpu.usage.utilization)) }
                    Divider()
                    HStack { Text("Renderer").foregroundStyle(.secondary); Spacer(); Text(String(format: "%.1f%%", gpu.usage.renderUtilization)) }
                    Divider()
                    HStack { Text("Tiler").foregroundStyle(.secondary); Spacer(); Text(String(format: "%.1f%%", gpu.usage.tilerUtilization)) }
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


    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) { Circle().fill(color).frame(width: 6, height: 6); Text(label).foregroundStyle(.secondary) }
    }
}
