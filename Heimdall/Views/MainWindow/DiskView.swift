import SwiftUI

struct DiskView: View {
    @Environment(DiskState.self) private var disk

    var body: some View {
        @Bindable var diskBinding = disk
        ScrollView {
            VStack(spacing: 20) {
                HStack {
                    Text("Disk").font(.largeTitle).fontWeight(.bold)
                    Spacer()
                }
                .padding(.horizontal)

                ForEach(disk.disks.filter { VolumeFilter.isLocalWritable(mountPath: $0.id) }) { d in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "internaldrive").foregroundStyle(.blue)
                            Text(d.name).font(.headline)
                            Spacer()
                            Text(String(format: "%.1f%% used", d.usagePercent)).font(.caption).foregroundStyle(.secondary)
                        }
                        ProgressView(value: d.usagePercent, total: 100)
                            .tint(MetricColor.usage(d.usagePercent))
                        HStack {
                            Text("\(ByteFormatter.format(d.usedBytes)) used").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(ByteFormatter.format(d.freeBytes)) free").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(ByteFormatter.format(d.totalBytes)) total").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                }

                HistoryChartCard(
                    title: "I/O Throughput",
                    range: $diskBinding.historyRange,
                    series: [
                        .init(disk.filteredHistory, value: { Double($0.readBytesPerSec) }, color: .blue, label: "Read"),
                        .init(disk.filteredHistory, value: { Double($0.writeBytesPerSec) }, color: .green, label: "Write"),
                    ],
                    yFormatter: { ByteFormatter.formatSpeed($0) },
                    tooltipFormatter: { ByteFormatter.formatSpeed($0) },
                    height: 120
                ) {
                    EmptyView()
                } subheader: {
                    HStack(spacing: 20) {
                        Label("Read: \(ByteFormatter.formatSpeed(disk.io.readBytesPerSec))", systemImage: "arrow.down.circle.fill")
                            .foregroundStyle(.blue)
                        Label("Write: \(ByteFormatter.formatSpeed(disk.io.writeBytesPerSec))", systemImage: "arrow.up.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                    }
                    .font(.callout)
                }
                .padding(.horizontal)

                ProcessListView(title: "Top Disk Processes", processes: disk.topProcesses, processHistory: disk.processHistory)
                    .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
