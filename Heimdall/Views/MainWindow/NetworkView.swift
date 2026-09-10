import SwiftUI

struct NetworkView: View {
    @Environment(NetworkState.self) private var net

    var body: some View {
        @Bindable var netBinding = net
        ScrollView {
            VStack(spacing: 20) {
                HStack {
                    Text("Network").font(.largeTitle).fontWeight(.bold)
                    Spacer()
                }
                .padding(.horizontal)

                // Speed gauges
                HStack(spacing: 16) {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill").font(.title).foregroundStyle(.blue)
                        Text(ByteFormatter.formatSpeed(net.stats.downloadBytesPerSec))
                            .font(.title2).fontWeight(.bold).fontDesign(.rounded)
                        Text("Download").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))

                    VStack(spacing: 8) {
                        Image(systemName: "arrow.up.circle.fill").font(.title).foregroundStyle(.green)
                        Text(ByteFormatter.formatSpeed(net.stats.uploadBytesPerSec))
                            .font(.title2).fontWeight(.bold).fontDesign(.rounded)
                        Text("Upload").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal)

                // History chart
                HistoryChartCard(
                    title: "Traffic History",
                    range: $netBinding.historyRange,
                    series: [
                        .init(net.filteredHistory, value: { Double($0.downloadBytesPerSec) }, color: .blue, label: "Download"),
                        .init(net.filteredHistory, value: { Double($0.uploadBytesPerSec) }, color: .green, label: "Upload"),
                    ],
                    yFormatter: { ByteFormatter.formatSpeed($0) },
                    tooltipFormatter: { ByteFormatter.formatSpeed($0) }
                )
                .padding(.horizontal)

                // Totals
                HStack(spacing: 12) {
                    StatCard(title: "Total Download", value: ByteFormatter.format(net.stats.totalDownload),
                           icon: "arrow.down.doc.fill", color: .blue)
                    StatCard(title: "Total Upload", value: ByteFormatter.format(net.stats.totalUpload),
                           icon: "arrow.up.doc.fill", color: .green)
                }
                .padding(.horizontal)

                // Top processes using bandwidth
                if !net.topProcesses.isEmpty {
                    ProcessListView(title: "Top Bandwidth Processes", processes: net.topProcesses, processHistory: net.processHistory)
                        .padding(.horizontal)
                }

                // Interface details
                if let iface = net.stats.activeInterface {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "network").foregroundStyle(.blue)
                            Text("Interface").font(.headline)
                        }
                        detailRow("Name", iface.displayName)
                        detailRow("Status", iface.isUp ? "Up" : "Down")
                        detailRow("MAC", iface.macAddress)
                        if !iface.speed.isEmpty { detailRow("Speed", iface.speed) }
                        detailRow("Local IP", iface.localIP)
                        if !iface.ipv6.isEmpty { detailRow("IPv6", iface.ipv6) }
                    }
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                }

                // Address info
                VStack(alignment: .leading, spacing: 8) {
                    Text("Address").font(.headline)
                    if !net.stats.publicIP.isEmpty { detailRow("Public IP", net.stats.publicIP) }
                    if !net.stats.publicIPv6.isEmpty { detailRow("Public IPv6", net.stats.publicIPv6) }
                    if !net.stats.dnsServers.isEmpty {
                        detailRow("DNS Servers", net.stats.dnsServers.joined(separator: ", "))
                    }
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout).fontDesign(.rounded).textSelection(.enabled)
        }
    }

}
