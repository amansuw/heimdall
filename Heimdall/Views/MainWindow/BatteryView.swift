import SwiftUI

struct BatteryView: View {
    @Environment(BatteryState.self) private var bat

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HStack {
                    Text("Battery").font(.largeTitle).fontWeight(.bold)
                    Spacer()
                }
                .padding(.horizontal)

                if !bat.battery.hasBattery {
                    VStack(spacing: 12) {
                        Image(systemName: "battery.0percent").font(.system(size: 48)).foregroundStyle(.secondary)
                        Text("No battery detected").font(.headline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                } else {
                    HStack(spacing: 16) {
                        GaugeCard(title: "Level", percent: bat.battery.level,
                                  subtitle: String(format: "%.0f%%", bat.battery.level),
                                  icon: bat.battery.isCharging ? "battery.100percent.bolt" : "battery.100percent",
                                  color: bat.battery.level > 20 ? .green : .red)
                        GaugeCard(title: "Health", percent: bat.battery.healthPercent,
                                  subtitle: String(format: "%.0f%%", bat.battery.healthPercent),
                                  icon: "heart.fill",
                                  color: bat.battery.healthPercent > 80 ? .green : .yellow)
                    }
                    .padding(.horizontal)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Details").font(.headline)
                        detailRow("Source", bat.battery.source)
                        detailRow("Charging", bat.battery.isCharging ? "Yes" : "No")
                        detailRow("Capacity", "\(bat.battery.currentCapacity) / \(bat.battery.maxCapacity) mAh")
                        detailRow("Design Capacity", "\(bat.battery.designCapacity) mAh")
                        detailRow("Cycle Count", "\(bat.battery.cycleCount)")
                        detailRow("Temperature", TempFormatter.format(bat.battery.temperature))
                        detailRow("Voltage", String(format: "%.2f V", bat.battery.voltage))
                        detailRow("Power", String(format: "%.2f W", bat.battery.power))
                    }
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)

                    if bat.battery.adapterWatts > 0 {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Power Adapter").font(.headline)
                            detailRow("Watts", "\(bat.battery.adapterWatts) W")
                            detailRow("Current", "\(bat.battery.adapterCurrent) mA")
                            detailRow("Voltage", "\(bat.battery.adapterVoltage) mV")
                        }
                        .padding()
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                    }
                }
            }
            .padding(.vertical)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout).fontWeight(.medium).fontDesign(.rounded)
        }
    }
}
