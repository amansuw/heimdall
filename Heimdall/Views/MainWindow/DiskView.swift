import SwiftUI

struct DiskView: View {
    @Environment(DiskState.self) private var disk

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HStack {
                    Text("Disk").font(.largeTitle).fontWeight(.bold)
                    Spacer()
                }
                .padding(.horizontal)

                ForEach(disk.disks) { d in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "internaldrive").foregroundStyle(.blue)
                            Text(d.name).font(.headline)
                            Spacer()
                            Text(String(format: "%.1f%% used", d.usagePercent)).font(.caption).foregroundStyle(.secondary)
                        }
                        ProgressView(value: d.usagePercent, total: 100)
                            .tint(d.usagePercent > 90 ? .red : d.usagePercent > 75 ? .orange : .blue)
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

                VStack(alignment: .leading, spacing: 8) {
                    Text("I/O Throughput").font(.headline)
                    HStack(spacing: 20) {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                            Text("Read: \(ByteFormatter.formatSpeed(disk.io.readBytesPerSec))").font(.callout)
                        }
                        HStack {
                            Image(systemName: "arrow.up.circle.fill").foregroundStyle(.green)
                            Text("Write: \(ByteFormatter.formatSpeed(disk.io.writeBytesPerSec))").font(.callout)
                        }
                    }
                    let historyArray = disk.ioHistory.toArray()
                    if historyArray.count >= 2 {
                        CanvasMultiLineChart(series: [
                            .init(data: historyArray.map { Double($0.readBytesPerSec) }, color: .blue),
                            .init(data: historyArray.map { Double($0.writeBytesPerSec) }, color: .green),
                        ])
                        .frame(height: 120)
                    }
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                ProcessListView(title: "Top Disk Processes", processes: disk.topProcesses)
                    .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
