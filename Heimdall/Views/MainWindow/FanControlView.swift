import SwiftUI

struct FanControlView: View {
    @Environment(FanState.self) private var fan

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HStack {
                    Text("Fan Control").font(.largeTitle).fontWeight(.bold)
                    Spacer()
                    if !fan.hasWriteAccess {
                        Button("Enable Control") {
                            NotificationCenter.default.post(name: .requestFanAccess, object: nil)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.horizontal)

                if fan.isYielding {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Waiting for thermalmonitord to yield...").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                }

                // Mode selector
                @Bindable var fanBinding = fan
                Picker("Control Mode", selection: $fanBinding.controlMode) {
                    ForEach(FanControlMode.allCases) { mode in
                        Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .onChange(of: fan.controlMode) { _, newMode in
                    NotificationCenter.default.post(name: .fanControlModeChanged, object: newMode)
                }

                // Fan cards
                ForEach(fan.fans) { f in
                    VStack(spacing: 12) {
                        HStack {
                            Image(systemName: "fan.fill").font(.title2).foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.name).font(.headline)
                                Text(f.isManual ? "Manual" : "Automatic").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing) {
                                HStack(alignment: .firstTextBaseline, spacing: 2) {
                                    Text(String(format: "%.0f", f.currentSpeed))
                                        .font(.title2).fontWeight(.bold).fontDesign(.rounded)
                                    Text("RPM").font(.caption).foregroundStyle(.secondary)
                                }
                                Text(String(format: "%.0f%%", f.speedPercentage))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }

                        ProgressView(value: max(0, min(f.speedPercentage, 100)), total: 100)
                            .tint(speedColor(f.speedPercentage))

                        HStack {
                            Text(String(format: "%.0f RPM", f.minSpeed)).font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.0f RPM", f.maxSpeed)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                }

                if fan.fans.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "fan.slash").font(.system(size: 48)).foregroundStyle(.secondary)
                        Text("No fans detected").font(.headline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                }

                // Quick presets
                if fan.hasWriteAccess {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Quick Presets").font(.headline)
                        HStack(spacing: 8) {
                            presetButton("Auto", isActive: fan.unifiedSpeedLabel == "Auto") {
                                NotificationCenter.default.post(name: .fanSetAllAuto, object: nil)
                            }
                            presetButton("25%", isActive: fan.unifiedSpeedLabel == "25%") {
                                NotificationCenter.default.post(name: .fanSetAllSpeed, object: 25.0)
                            }
                            presetButton("50%", isActive: fan.unifiedSpeedLabel == "50%") {
                                NotificationCenter.default.post(name: .fanSetAllSpeed, object: 50.0)
                            }
                            presetButton("75%", isActive: fan.unifiedSpeedLabel == "75%") {
                                NotificationCenter.default.post(name: .fanSetAllSpeed, object: 75.0)
                            }
                            presetButton("Max", isActive: fan.unifiedSpeedLabel == "Max") {
                                NotificationCenter.default.post(name: .fanSetAllSpeed, object: 100.0)
                            }
                        }
                    }
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)

                    // Manual slider
                    if fan.controlMode == .manual {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Manual Speed").font(.headline)
                            HStack {
                                Slider(value: $fanBinding.manualSpeedPercentage, in: 0...100, step: 5)
                                Text(String(format: "%.0f%%", fan.manualSpeedPercentage))
                                    .font(.callout).fontDesign(.rounded).frame(width: 40)
                            }
                            Button("Apply") {
                                NotificationCenter.default.post(name: .fanApplyManual, object: nil)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding()
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                    }
                }

                if fan.isControlActive {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        Text("Manual fan control is active. Fans will reset to automatic on quit.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func speedColor(_ pct: Double) -> Color {
        if pct < 30 { return .green }; if pct < 60 { return .yellow }; if pct < 80 { return .orange }; return .red
    }

    private func presetButton(_ label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption).fontWeight(.medium)
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .background(isActive ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(isActive ? Color.accentColor : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(fan.isYielding)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let requestFanAccess = Notification.Name("requestFanAccess")
    static let fanControlModeChanged = Notification.Name("fanControlModeChanged")
    static let fanSetAllAuto = Notification.Name("fanSetAllAuto")
    static let fanSetAllSpeed = Notification.Name("fanSetAllSpeed")
    static let fanApplyManual = Notification.Name("fanApplyManual")
}
