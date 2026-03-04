import SwiftUI

struct RAMView: View {
    @Environment(RAMState.self) private var ram

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Memory").font(.largeTitle).fontWeight(.bold)
                        Text(ByteFormatter.format(ram.memory.total)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal)

                HStack(spacing: 16) {
                    GaugeCard(title: "Used", percent: ram.memory.usagePercent,
                              subtitle: ByteFormatter.format(ram.memory.used),
                              icon: "memorychip", color: pressureColor)
                    VStack(alignment: .leading, spacing: 8) {
                        memRow("App Memory", ByteFormatter.format(ram.memory.app), .blue)
                        memRow("Wired", ByteFormatter.format(ram.memory.wired), .orange)
                        memRow("Compressed", ByteFormatter.format(ram.memory.compressed), .purple)
                        memRow("Free", ByteFormatter.format(ram.memory.free), .green)
                        memRow("Swap", ByteFormatter.format(ram.memory.swap), .red)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Memory Pressure").font(.headline)
                    HStack(spacing: 8) {
                        Circle().fill(pressureColor).frame(width: 10, height: 10)
                        Text(pressureText).font(.callout)
                    }
                    ProgressView(value: ram.memory.usagePercent, total: 100)
                        .tint(pressureColor)
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                // Usage history
                VStack(alignment: .leading, spacing: 8) {
                    Text("Usage History").font(.headline)
                    @Bindable var ramBinding = ram
                    HStack(spacing: 6) {
                        Text("Range")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Range", selection: $ramBinding.historyRange) {
                            ForEach(HistoryRange.allCases) { range in
                                Text(range.rawValue).tag(range)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    let historyArray = ram.filteredHistory
                    if historyArray.count >= 2 {
                        CanvasLineChart(
                            data: historyArray.map(\.usagePercent),
                            color: pressureColor,
                            fillColor: pressureColor.opacity(0.15),
                            yRange: 0...100,
                            label: "Usage %"
                        )
                        .frame(height: 150)
                    } else {
                        ProgressView().frame(height: 100)
                    }
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                ProcessListView(title: "Top Memory Processes", processes: ram.topProcesses)
                    .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func memRow(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout).fontWeight(.medium).fontDesign(.rounded)
        }
    }

    private var pressureColor: Color {
        switch ram.memory.pressureLevel {
        case 4: return .red
        case 2: return .yellow
        default: return .green
        }
    }

    private var pressureText: String {
        switch ram.memory.pressureLevel {
        case 4: return "Critical"
        case 2: return "Warning"
        default: return "Normal"
        }
    }
}
