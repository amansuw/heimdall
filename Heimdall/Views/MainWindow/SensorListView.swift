import SwiftUI

struct SensorListView: View {
    @Environment(SensorState.self) private var sensors
    @State private var searchText = ""
    @State private var selectedCategory: SensorCategory? = nil

    private var filteredReadings: [SensorReading] {
        var results = sensors.readings
        if let cat = selectedCategory {
            results = results.filter { $0.category == cat }
        }
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            results = results.filter { $0.name.lowercased().contains(query) || $0.key.lowercased().contains(query) }
        }
        return results
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Sensors").font(.largeTitle).fontWeight(.bold)
                Spacer()
                if sensors.isDiscovering {
                    ProgressView().controlSize(.small)
                    Text("Discovering...").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(sensors.readings.count) sensors").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()

            // Filter bar
            HStack(spacing: 8) {
                TextField("Search sensors...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)

                Picker("Category", selection: $selectedCategory) {
                    Text("All").tag(nil as SensorCategory?)
                    ForEach(SensorCategory.allCases) { cat in
                        Text(cat.rawValue).tag(cat as SensorCategory?)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 400)

                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            // Sensor table
            List(filteredReadings) { reading in
                HStack {
                    Image(systemName: reading.category.icon)
                        .foregroundStyle(categoryColor(reading.category))
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(reading.name).font(.callout)
                        Text(reading.key).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(reading.formattedValue)
                        .font(.callout).fontWeight(.medium).fontDesign(.rounded)
                        .foregroundStyle(categoryColor(reading.category))
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func categoryColor(_ cat: SensorCategory) -> Color {
        switch cat {
        case .temperature: return .orange
        case .voltage: return .blue
        case .current: return .purple
        case .power: return .red
        case .fan: return .cyan
        }
    }
}
