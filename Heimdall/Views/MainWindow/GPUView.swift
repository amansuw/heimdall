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
                              icon: "square.3.layers.3d.top.filled", color: gaugeColor(gpu.usage.utilization))
                    GaugeCard(title: "Renderer", percent: gpu.usage.renderUtilization,
                              subtitle: String(format: "%.1f%%", gpu.usage.renderUtilization),
                              icon: "paintbrush.fill", color: gaugeColor(gpu.usage.renderUtilization))
                    GaugeCard(title: "Tiler", percent: gpu.usage.tilerUtilization,
                              subtitle: String(format: "%.1f%%", gpu.usage.tilerUtilization),
                              icon: "square.grid.3x3.fill", color: gaugeColor(gpu.usage.tilerUtilization))
                }
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
            }
            .padding(.vertical)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func gaugeColor(_ v: Double) -> Color {
        if v < 30 { return .green }; if v < 60 { return .yellow }; if v < 80 { return .orange }; return .red
    }
}
