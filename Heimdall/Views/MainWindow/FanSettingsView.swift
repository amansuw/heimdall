import SwiftUI

struct FanSettingsView: View {
    @Environment(FanState.self) private var fan
    @Environment(SensorState.self) private var sensors
    @Environment(ProfileState.self) private var profileState
    @State private var showAccessPrompt = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header
                HStack {
                    Text("Fan Settings").font(.largeTitle).fontWeight(.bold)
                    Spacer()
                    if !fan.hasWriteAccess {
                        Button("Enable Control") {
                            showAccessPrompt = true
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

                // 1. Profiles at top
                profilesSection
                    .padding(.horizontal)

                // 2. Control mode card picker + fan cards
                fanControlSection
                    .padding(.horizontal)

                // 3. Manual speed — only in manual mode
                if fan.controlMode == .manual {
                    manualSpeedSection
                        .padding(.horizontal)
                }

                // 4. Fan curve — only in curve mode
                if fan.controlMode == .curve {
                    fanCurveSection
                        .padding(.horizontal)
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
        .alert("Enable Fan Control", isPresented: $showAccessPrompt) {
            Button("Cancel", role: .cancel) {}
            Button("Continue", role: .destructive) {
                NotificationCenter.default.post(name: .requestFanAccess, object: nil)
            }
        } message: {
            Text("Fan control requires installing the Heimdall helper (one-time admin password) so we can talk to the SMC. Heimdall will momentarily pause while the helper requests access. Continue?")
        }
    }

    // MARK: - Fan Control Section (mode picker + fan cards)

    @ViewBuilder
    private var fanControlSection: some View {
        @Bindable var fanBinding = fan
        VStack(spacing: 16) {
            // Boreas-style mode card buttons
            VStack(alignment: .leading, spacing: 10) {
                Text("Control Mode").font(.headline)
                HStack(spacing: 10) {
                    ForEach(FanControlMode.allCases) { mode in
                        controlModeCard(mode: mode, isSelected: fan.controlMode == mode) {
                            selectControlMode(mode)
                        }
                    }
                }
            }

            // Fan cards — 50/50 split when 2 fans, stacked otherwise
            if fan.fans.count == 2 {
                HStack(alignment: .top, spacing: 10) {
                    fanCard(fan.fans[0]).frame(maxWidth: .infinity)
                    fanCard(fan.fans[1]).frame(maxWidth: .infinity)
                }
            } else {
                ForEach(fan.fans) { f in
                    fanCard(f)
                }
            }

            if fan.fans.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "fan.slash").font(.system(size: 32)).foregroundStyle(.secondary)
                    Text("No fans detected").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 20)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Boreas-style Mode Card Button

    private func controlModeCard(mode: FanControlMode, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: mode.icon)
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(mode.rawValue)
                    .font(.caption)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                isSelected ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isSelected ? 1.5 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Individual Fan Card

    private func fanCard(_ f: FanInfo) -> some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "fan.fill").font(.title3).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text(f.name).font(.subheadline).fontWeight(.medium)
                    Text(f.isManual ? "Manual" : "Automatic").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(String(format: "%.0f", f.currentSpeed))
                            .font(.title3).fontWeight(.bold).fontDesign(.rounded)
                        Text("RPM").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(String(format: "%.0f%%", f.speedPercentage))
                        .font(.caption2).foregroundStyle(.secondary)
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
        .padding(10)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Manual Speed Section (only visible in manual mode)

    @ViewBuilder
    private var manualSpeedSection: some View {
        @Bindable var fanBinding = fan
        VStack(alignment: .leading, spacing: 12) {
            Text("Manual Speed").font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("0%").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: $fanBinding.manualSpeedPercentage, in: 0...100, step: 1)
                        .onChange(of: fan.manualSpeedPercentage) { _, _ in
                            guard ensureWriteAccess() else { return }
                            NotificationCenter.default.post(name: .fanApplyManual, object: nil)
                        }
                    Text("100%").font(.caption2).foregroundStyle(.secondary)
                }
                Text(String(format: "%.0f%%", fan.manualSpeedPercentage))
                    .font(.title3).fontWeight(.bold).fontDesign(.rounded)
            }

            if fan.hasWriteAccess {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Quick Presets").font(.subheadline).fontWeight(.medium)
                    HStack(spacing: 8) {
                        presetButton("Min", isActive: fan.manualSpeedPercentage == 1) {
                            guard ensureWriteAccess() else { return }
                            fan.manualSpeedPercentage = 1
                            NotificationCenter.default.post(name: .fanApplyManual, object: nil)
                        }
                        presetButton("25%", isActive: fan.manualSpeedPercentage == 25) {
                            guard ensureWriteAccess() else { return }
                            fan.manualSpeedPercentage = 25
                            NotificationCenter.default.post(name: .fanApplyManual, object: nil)
                        }
                        presetButton("50%", isActive: fan.manualSpeedPercentage == 50) {
                            guard ensureWriteAccess() else { return }
                            fan.manualSpeedPercentage = 50
                            NotificationCenter.default.post(name: .fanApplyManual, object: nil)
                        }
                        presetButton("75%", isActive: fan.manualSpeedPercentage == 75) {
                            guard ensureWriteAccess() else { return }
                            fan.manualSpeedPercentage = 75
                            NotificationCenter.default.post(name: .fanApplyManual, object: nil)
                        }
                        presetButton("Max", isActive: fan.manualSpeedPercentage == 100) {
                            guard ensureWriteAccess() else { return }
                            fan.manualSpeedPercentage = 100
                            NotificationCenter.default.post(name: .fanApplyManual, object: nil)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Fan Curve Section (only visible in curve mode)

    @State private var curve = FanCurve()
    @State private var selectedSensorKey = "AGG_CPU_AVG"

    private func autoApplyCurve() {
        guard ensureWriteAccess() else { return }
        curve.sensorKey = selectedSensorKey
        fan.activeCurve = curve
        NotificationCenter.default.post(name: .fanControlModeChanged, object: FanControlMode.curve)
    }

    @ViewBuilder
    private var fanCurveSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fan Curve").font(.headline)

            // Sensor picker
            HStack {
                Text("Sensor:").font(.caption).foregroundStyle(.secondary)
                Picker("Sensor", selection: $selectedSensorKey) {
                    Text("CPU Average").tag("AGG_CPU_AVG")
                    Text("CPU Hottest").tag("AGG_CPU_MAX")
                    Text("GPU Average").tag("AGG_GPU_AVG")
                    ForEach(sensors.temperatureReadings.prefix(20)) { reading in
                        Text(reading.name).tag(reading.key)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
            }

            // Curve canvas
            GeometryReader { geo in
                let size = geo.size
                Canvas { context, canvasSize in
                    drawCurveCanvas(context: context, size: canvasSize)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            handleDrag(value: value, size: size)
                        }
                        .onEnded { _ in
                            autoApplyCurve()
                        }
                )
            }
            .frame(height: 220)
            .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            .onChange(of: selectedSensorKey) { _, _ in autoApplyCurve() }

            // Axis labels
            HStack {
                Text("20°C").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("Temperature").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("110°C").font(.caption2).foregroundStyle(.secondary)
            }

            // Editable control points table
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Control Points").font(.subheadline).fontWeight(.medium)
                    Spacer()
                    Button(action: addPoint) {
                        Image(systemName: "plus.circle.fill").foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                }

                ForEach(curve.sortedPoints) { point in
                    editablePointRow(point: point)
                }
            }

            // Reset only
            HStack {
                Spacer()
                Button("Reset") {
                    curve = FanCurve()
                    autoApplyCurve()
                }
                .controlSize(.small)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Editable Point Row

    @ViewBuilder
    private func editablePointRow(point: CurvePoint) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                // Temp field
                HStack(spacing: 3) {
                    TextField("", value: Binding(
                        get: { Int(point.temperature) },
                        set: {
                            curve.updatePoint(id: point.id, temperature: max(20, min(110, Double($0))))
                            autoApplyCurve()
                        }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 44)
                    .font(.caption)
                    .multilineTextAlignment(.trailing)
                    Text("°C").font(.caption2).foregroundStyle(.secondary)
                }

                Image(systemName: "arrow.right").foregroundStyle(.secondary).font(.caption2)

                // Speed field
                HStack(spacing: 3) {
                    TextField("", value: Binding(
                        get: { Int(point.fanSpeed) },
                        set: {
                            curve.updatePoint(id: point.id, fanSpeed: max(0, min(100, Double($0))))
                            autoApplyCurve()
                        }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 44)
                    .font(.caption)
                    .multilineTextAlignment(.trailing)
                    Text("%").font(.caption2).foregroundStyle(.secondary)
                }

                Spacer()

                if curve.points.count > 2 {
                    Button { removePoint(id: point.id) } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.red).font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Sliders
            HStack(spacing: 8) {
                Image(systemName: "thermometer").font(.caption2).foregroundStyle(.secondary).frame(width: 12)
                Slider(value: Binding(
                    get: { point.temperature },
                    set: { curve.updatePoint(id: point.id, temperature: $0) }
                ), in: 20...110, step: 1)
                .onChange(of: point.temperature) { _, _ in autoApplyCurve() }
                .controlSize(.mini)
            }
            HStack(spacing: 8) {
                Image(systemName: "fan").font(.caption2).foregroundStyle(.secondary).frame(width: 12)
                Slider(value: Binding(
                    get: { point.fanSpeed },
                    set: { curve.updatePoint(id: point.id, fanSpeed: $0) }
                ), in: 0...100, step: 1)
                .onChange(of: point.fanSpeed) { _, _ in autoApplyCurve() }
                .controlSize(.mini)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
        Divider()
    }

    private func selectControlMode(_ mode: FanControlMode) {
        if mode != .automatic && !fan.hasWriteAccess {
            showAccessPrompt = true
            return
        }

        fan.controlMode = mode
        switch mode {
        case .automatic:
            if let defaultProfile = profileState.profiles.first(where: { $0.name == "Default" }) {
                profileState.setActiveProfile(defaultProfile)
            }
        case .manual, .curve:
            profileState.setActiveProfile(nil)
        }
        NotificationCenter.default.post(name: .fanControlModeChanged, object: mode)
    }

    private func ensureWriteAccess() -> Bool {
        if fan.hasWriteAccess { return true }
        showAccessPrompt = true
        return false
    }

    // MARK: - Profiles Section

    @State private var showingNewProfile = false
    @State private var newProfileName = ""

    @ViewBuilder
    private var profilesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Profiles").font(.headline)
                Spacer()
                Button(action: { showingNewProfile = true }) {
                    Label("New Profile", systemImage: "plus").controlSize(.small)
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(profileState.profiles, id: \.id) { profile in
                    profileCard(profile: profile)
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: $showingNewProfile) {
            VStack(spacing: 16) {
                Text("New Profile").font(.headline)
                TextField("Profile Name", text: $newProfileName)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Cancel") { showingNewProfile = false }
                    Button("Create") {
                        let profile = FanProfile(name: newProfileName, mode: .curve, curve: curve)
                        profileState.addCustomProfile(profile)
                        newProfileName = ""
                        showingNewProfile = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newProfileName.isEmpty)
                }
            }
            .padding()
            .frame(width: 300)
        }
    }

    // MARK: - Profile Card with Curve Preview

    @ViewBuilder
    private func profileCard(profile: FanProfile) -> some View {
        let isActive = profileState.activeProfile?.id == profile.id

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(profileColor(profile)).frame(width: 8, height: 8)
                Text(profile.name).font(.caption).fontWeight(.medium).lineLimit(1)
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                }
            }

            // Curve preview
            if let c = profile.curve {
                curvePreview(curve: c)
                    .frame(height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                HStack {
                    Image(systemName: profile.mode == .automatic ? "gearshape" : "slider.horizontal.3")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(profile.mode.rawValue.capitalized).font(.caption2).foregroundStyle(.secondary)
                    if let speed = profile.manualSpeedPercentage {
                        Text("· \(Int(speed))%").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 40)
            }

            HStack {
                Button(isActive ? "Active" : "Activate") { activateProfile(profile) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .disabled(isActive)
                Spacer()
                if !profile.isBuiltIn {
                    Button { profileState.removeProfile(profile) } label: {
                        Image(systemName: "trash").foregroundStyle(.red).font(.caption2)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(8)
        .background(
            isActive ? Color.accentColor.opacity(0.05) : Color.secondary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? Color.accentColor : .clear, lineWidth: 1)
        )
    }

    // MARK: - Curve Preview Canvas

    @ViewBuilder
    private func curvePreview(curve: FanCurve) -> some View {
        Canvas { context, size in
            let sorted = curve.sortedPoints
            guard sorted.count >= 2 else { return }

            var path = Path()
            for (i, point) in sorted.enumerated() {
                let x = ((point.temperature - 20) / 90) * size.width
                let y = size.height - (CGFloat(point.fanSpeed) / 100.0) * size.height
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }

            // Fill
            var fillPath = path
            if let last = sorted.last {
                fillPath.addLine(to: CGPoint(x: ((last.temperature - 20) / 90) * size.width, y: size.height))
            }
            if let first = sorted.first {
                fillPath.addLine(to: CGPoint(x: ((first.temperature - 20) / 90) * size.width, y: size.height))
            }
            fillPath.closeSubpath()
            context.fill(fillPath, with: .color(.blue.opacity(0.1)))
            context.stroke(path, with: .color(.blue.opacity(0.6)), lineWidth: 1)
        }
        .background(Color.secondary.opacity(0.03))
    }

    // MARK: - Curve Canvas Drawing

    private func drawCurveCanvas(context: GraphicsContext, size: CGSize) {
        let sorted = curve.sortedPoints
        guard sorted.count >= 2 else { return }

        // Grid lines
        for i in stride(from: 0.0, through: 100.0, by: 25.0) {
            let y = size.height - (CGFloat(i) / 100.0) * size.height
            var gridPath = Path()
            gridPath.move(to: CGPoint(x: 0, y: y))
            gridPath.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(gridPath, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
        }

        for temp in stride(from: 30.0, through: 100.0, by: 10.0) {
            let x = ((temp - 20) / 90) * size.width
            var gridPath = Path()
            gridPath.move(to: CGPoint(x: x, y: 0))
            gridPath.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(gridPath, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
        }

        // Curve line
        var linePath = Path()
        for (i, point) in sorted.enumerated() {
            let x = ((point.temperature - 20) / 90) * size.width
            let y = size.height - (CGFloat(point.fanSpeed) / 100.0) * size.height
            if i == 0 { linePath.move(to: CGPoint(x: x, y: y)) }
            else { linePath.addLine(to: CGPoint(x: x, y: y)) }
        }
        context.stroke(linePath, with: .color(.blue), lineWidth: 2)

        // Fill under curve
        var fillPath = linePath
        if let lastPoint = sorted.last {
            fillPath.addLine(to: CGPoint(x: ((lastPoint.temperature - 20) / 90) * size.width, y: size.height))
        }
        if let firstPoint = sorted.first {
            fillPath.addLine(to: CGPoint(x: ((firstPoint.temperature - 20) / 90) * size.width, y: size.height))
        }
        fillPath.closeSubpath()
        context.fill(fillPath, with: .color(.blue.opacity(0.1)))

        // Control points
        for point in sorted {
            let x = ((point.temperature - 20) / 90) * size.width
            let y = size.height - (CGFloat(point.fanSpeed) / 100.0) * size.height
            let radius: CGFloat = 6
            let circle = Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
            context.fill(circle, with: .color(.blue))
            context.stroke(circle, with: .color(.white), lineWidth: 2)
        }

        // Current temperature indicator
        let currentTemp = sensorTemp(for: selectedSensorKey)
        if currentTemp > 0 {
            let curX = ((currentTemp - 20) / 90) * size.width
            var indicatorPath = Path()
            indicatorPath.move(to: CGPoint(x: curX, y: 0))
            indicatorPath.addLine(to: CGPoint(x: curX, y: size.height))
            context.stroke(indicatorPath, with: .color(.red.opacity(0.5)),
                         style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
    }

    // MARK: - Helpers

    private func sensorTemp(for key: String) -> Double {
        switch key {
        case "AGG_CPU_AVG": return sensors.averageCPUTemp
        case "AGG_CPU_MAX": return sensors.hottestCPUTemp
        case "AGG_GPU_AVG": return sensors.averageGPUTemp
        default: return sensors.temperatureReadings.first(where: { $0.key == key })?.value ?? 0
        }
    }

    private func handleDrag(value: DragGesture.Value, size: CGSize) {
        let temp = (value.location.x / size.width) * 90 + 20
        let speed = (1 - value.location.y / size.height) * 100
        let clampedTemp = max(20, min(110, temp))
        let clampedSpeed = max(0, min(100, speed))

        if let nearest = curve.sortedPoints.min(by: { abs($0.temperature - clampedTemp) < abs($1.temperature - clampedTemp) }) {
            let dist = abs(nearest.temperature - clampedTemp)
            if dist < 8 {
                curve.updatePoint(id: nearest.id, temperature: clampedTemp, fanSpeed: clampedSpeed)
            }
        }
    }

    private func addPoint() {
        let sorted = curve.sortedPoints
        let midTemp = ((sorted.first?.temperature ?? 30) + (sorted.last?.temperature ?? 90)) / 2
        curve.addPoint(CurvePoint(temperature: midTemp, fanSpeed: 50))
    }

    private func removePoint(id: UUID) {
        if let idx = curve.points.firstIndex(where: { $0.id == id }) {
            curve.removePoint(at: idx)
        }
    }

    private func activateProfile(_ profile: FanProfile) {
        profileState.setActiveProfile(profile)

        switch profile.mode {
        case .automatic:
            fan.controlMode = .automatic
            NotificationCenter.default.post(name: .fanControlModeChanged, object: FanControlMode.automatic)
        case .manual:
            if let speed = profile.manualSpeedPercentage {
                fan.manualSpeedPercentage = speed
                fan.controlMode = .manual
                NotificationCenter.default.post(name: .fanControlModeChanged, object: FanControlMode.manual)
            }
        case .curve:
            if let c = profile.curve {
                curve = c
                fan.activeCurve = c
                fan.controlMode = .curve
                NotificationCenter.default.post(name: .fanControlModeChanged, object: FanControlMode.curve)
            }
        }
    }

    private func speedColor(_ pct: Double) -> Color {
        if pct < 30 { return .green }; if pct < 60 { return .yellow }; if pct < 80 { return .orange }; return .red
    }

    private func profileColor(_ profile: FanProfile) -> Color {
        switch profile.name {
        case "Default": return .green
        case "Silent": return .blue
        case "Balanced": return .yellow
        case "Performance": return .orange
        case "Max": return .red
        default: return .purple
        }
    }

    private func presetButton(_ label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption2).fontWeight(.medium)
                .frame(maxWidth: .infinity).padding(.vertical, 4)
                .background(isActive ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(isActive ? Color.accentColor : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(fan.isYielding)
    }
}
