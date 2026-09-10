import SwiftUI

struct FanSettingsView: View {
    @Environment(FanState.self) private var fan
    @Environment(SensorState.self) private var sensors
    @Environment(ProfileState.self) private var profileState
    @State private var showAccessPrompt = false
    @State private var renamingProfile: FanProfile?
    @State private var renameText = ""

    /// Applying a fan target costs ~2.4s of SMC writes, so continuous controls (sliders, text
    /// fields) coalesce into a single trailing apply instead of one per step.
    @State private var manualApplyWork: DispatchWorkItem?
    @State private var curveApplyWork: DispatchWorkItem?
    private static let applyDebounce: TimeInterval = 0.25

    private static let speedPresets: [Int] = [1, 25, 50, 75, 100]

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

                // 2. Selected profile editor (curve / manual)
                if profileState.selectedProfile != nil {
                    selectedProfileEditor
                        .padding(.horizontal)
                }

                // 3. Control mode card picker + fan cards
                fanControlSection
                    .padding(.horizontal)

                // 4. Manual speed — only in manual mode (live control, not profile edit)
                if fan.controlMode == .manual {
                    manualSpeedSection
                        .padding(.horizontal)
                }

                // 5. Live fan curve — only in curve mode when no profile is selected for editing
                if fan.controlMode == .curve && profileState.selectedProfile == nil {
                    liveFanCurveSection
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
        .alert("Rename Profile", isPresented: Binding(
            get: { renamingProfile != nil },
            set: { if !$0 { renamingProfile = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingProfile = nil }
            Button("Save") {
                if let profile = renamingProfile {
                    profileState.renameProfile(profile, to: renameText)
                }
                renamingProfile = nil
            }
            .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Enter a new name for this profile.")
        }
        .onAppear {
            if profileState.selectedProfile == nil, let active = profileState.activeProfile {
                selectProfile(active)
            }
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
                .tint(MetricColor.usage(f.speedPercentage))
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
                    Slider(value: $fanBinding.manualSpeedPercentage, in: 0...100, step: 1) { editing in
                        // Apply the moment the drag ends; intermediate steps are debounced.
                        if !editing { applyManualSpeed(debounced: false) }
                    }
                    .onChange(of: fan.manualSpeedPercentage) { _, _ in
                        applyManualSpeed(debounced: true)
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
                        ForEach(Self.speedPresets, id: \.self) { percent in
                            presetButton(presetLabel(percent),
                                         isActive: fan.manualSpeedPercentage == Double(percent)) {
                                guard ensureWriteAccess() else { return }
                                fan.manualSpeedPercentage = Double(percent)
                                applyManualSpeed(debounced: false)
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Curve / Profile Editing State

    @State private var curve = FanCurve()
    @State private var selectedSensorKey = "AGG_CPU_AVG"
    @State private var editingManualSpeed: Double = 100
    @State private var hasUnsavedProfileChanges = false
    @State private var editingProfileMode: FanProfileMode = .curve
    @State private var curveHoverLocation: CGPoint? = nil
    @State private var draggingPointID: UUID? = nil
    @State private var isDraggingCurve = false

    private static let curveMinTemp: Double = 20
    private static let curveMaxTemp: Double = 110
    /// Minimum °C between adjacent control points.
    private static let minPointSpacing: Double = 1
    /// How close (in points) a click must be to grab an existing control point / the curve line.
    private static let pointGrabRadius: CGFloat = 12
    private static let lineGrabRadius: CGFloat = 10
    /// Horizontal clearance a click needs from existing points before it inserts a new one.
    private static let minInsertDistance: CGFloat = 20

    /// Pushes the edited curve into live state right away (cheap) but coalesces the notification
    /// that kicks off the SMC write sequence (expensive).
    private func autoApplyCurve() {
        guard ensureWriteAccess() else { return }
        curve.sensorKey = selectedSensorKey
        fan.activeCurve = curve

        curveApplyWork?.cancel()
        let work = DispatchWorkItem {
            NotificationCenter.default.post(name: .fanControlModeChanged, object: FanControlMode.curve)
        }
        curveApplyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.applyDebounce, execute: work)
    }

    /// Requests a manual-speed apply, either immediately (gesture ended, preset tapped) or
    /// coalesced with the other changes in this drag.
    private func applyManualSpeed(debounced: Bool) {
        guard ensureWriteAccess() else { return }

        manualApplyWork?.cancel()
        let work = DispatchWorkItem {
            NotificationCenter.default.post(name: .fanApplyManual, object: nil)
        }
        manualApplyWork = work

        if debounced {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.applyDebounce, execute: work)
        } else {
            work.perform()
        }
    }

    private func presetLabel(_ percent: Int) -> String {
        if percent <= 1 { return "Min" }
        if percent >= 100 { return "Max" }
        return "\(percent)%"
    }

    private func markProfileEdited() {
        hasUnsavedProfileChanges = true
    }

    // MARK: - Selected Profile Editor

    @ViewBuilder
    private var selectedProfileEditor: some View {
        if let profile = profileState.selectedProfile {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Edit \(profile.name)").font(.headline)
                    Spacer()
                    if hasUnsavedProfileChanges {
                        Button("Reset") {
                            resetSelectedProfileToDefault()
                        }
                        .controlSize(.small)
                        Button("Apply") {
                            applySelectedProfileEdits()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }

                switch editingProfileMode {
                case .automatic:
                    automaticProfileEditor(profile: profile)
                case .manual:
                    manualProfileEditor
                case .curve:
                    profileCurveEditor
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private func automaticProfileEditor(profile: FanProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This profile uses the system automatic fan curve.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Customize Curve") {
                curve = FanCurve(name: profile.name)
                selectedSensorKey = curve.sensorKey
                editingProfileMode = .curve
                markProfileEdited()
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var manualProfileEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("0%").font(.caption2).foregroundStyle(.secondary)
                Slider(value: $editingManualSpeed, in: 0...100, step: 1)
                    .onChange(of: editingManualSpeed) { _, _ in markProfileEdited() }
                Text("100%").font(.caption2).foregroundStyle(.secondary)
            }
            Text(String(format: "%.0f%%", editingManualSpeed))
                .font(.title3).fontWeight(.bold).fontDesign(.rounded)

            Button("Convert to Curve") {
                curve = FanCurve(name: profileState.selectedProfile?.name ?? "Custom")
                selectedSensorKey = curve.sensorKey
                editingProfileMode = .curve
                markProfileEdited()
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var profileCurveEditor: some View {
        // Profile edits are staged until Apply, so they only mark the profile dirty.
        curveEditorContent(onEdit: markProfileEdited, onReset: nil)
    }

    // MARK: - Live Fan Curve (control mode, no profile selected)

    @ViewBuilder
    private var liveFanCurveSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fan Curve").font(.headline)
            curveEditorContent(onEdit: autoApplyCurve, onReset: {
                let name = curve.name
                curve = FanCurve(name: name)
                selectedSensorKey = curve.sensorKey
                autoApplyCurve()
            })
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    /// - Parameters:
    ///   - onEdit: called whenever the curve changes (live apply, or mark the profile dirty).
    ///   - onReset: when non-nil, shows a Reset row running this closure.
    @ViewBuilder
    private func curveEditorContent(onEdit: @escaping () -> Void,
                                    onReset: (() -> Void)?) -> some View {
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
            ZStack(alignment: .topLeading) {
                Canvas { context, canvasSize in
                    drawCurveCanvas(context: context, size: canvasSize, hover: curveHoverLocation)
                }

                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let loc):
                            curveHoverLocation = loc
                        case .ended:
                            curveHoverLocation = nil
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                curveHoverLocation = value.location
                                handleDrag(value: value, size: size)
                            }
                            .onEnded { _ in
                                draggingPointID = nil
                                isDraggingCurve = false
                                onEdit()
                            }
                    )

                if curveHoverLocation != nil {
                    curveHoverTooltip(size: size)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 220)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .onChange(of: selectedSensorKey) { _, _ in
            onEdit()
        }

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
                Button(action: {
                    addPoint()
                    onEdit()
                }) {
                    Image(systemName: "plus.circle.fill").foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }

            ForEach(curve.sortedPoints) { point in
                editablePointRow(point: point, onEdit: onEdit)
            }
        }

        // Reset curve (live editor only — profile editor uses header Reset)
        if let onReset {
            HStack {
                Spacer()
                Button("Reset", action: onReset)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Editable Point Row

    @ViewBuilder
    private func editablePointRow(point: CurvePoint, onEdit: @escaping () -> Void) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                // Temp field
                HStack(spacing: 3) {
                    TextField("", value: Binding(
                        get: { Int(point.temperature) },
                        set: {
                            curve.updatePoint(id: point.id,
                                              temperature: constrainedTemperature(Double($0), for: point.id))
                            onEdit()
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
                            onEdit()
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
                    Button {
                        removePoint(id: point.id)
                        onEdit()
                    } label: {
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
                    set: { curve.updatePoint(id: point.id, temperature: constrainedTemperature($0, for: point.id)) }
                ), in: 20...110, step: 1)
                .onChange(of: point.temperature) { _, _ in
                    onEdit()
                }
                .controlSize(.mini)
            }
            HStack(spacing: 8) {
                Image(systemName: "fan").font(.caption2).foregroundStyle(.secondary).frame(width: 12)
                Slider(value: Binding(
                    get: { point.fanSpeed },
                    set: { curve.updatePoint(id: point.id, fanSpeed: $0) }
                ), in: 0...100, step: 1)
                .onChange(of: point.fanSpeed) { _, _ in
                    onEdit()
                }
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
        let isSelected = profileState.selectedProfile?.id == profile.id

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
                Button(isActive ? "Active" : "Activate") {
                    activateProfile(profile)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .disabled(isActive)
                Spacer()
                if !profile.isBuiltIn {
                    Button {
                        renameText = profile.name
                        renamingProfile = profile
                    } label: {
                        Image(systemName: "pencil").foregroundStyle(.secondary).font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .help("Rename")

                    Button {
                        profileState.removeProfile(profile)
                    } label: {
                        Image(systemName: "trash").foregroundStyle(.red).font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .help("Delete")
                }
            }
        }
        .padding(8)
        .background(
            isSelected ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : .clear, lineWidth: isSelected ? 1.5 : 0)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture {
            selectProfile(profile)
        }
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

    private func drawCurveCanvas(context: GraphicsContext, size: CGSize, hover: CGPoint?) {
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

        // Current sensor temp + running fan speed (red)
        let currentTemp = sensorTemp(for: selectedSensorKey)
        if currentTemp > 0, size.width > 0, size.height > 0 {
            let curX = ((currentTemp - 20) / 90) * size.width
            var indicatorPath = Path()
            indicatorPath.move(to: CGPoint(x: curX, y: 0))
            indicatorPath.addLine(to: CGPoint(x: curX, y: size.height))
            context.stroke(indicatorPath, with: .color(.red.opacity(0.5)),
                         style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

            let runningY = size.height - (CGFloat(fan.averageSpeedPercentage) / 100.0) * size.height
            let redDot = Path(ellipseIn: CGRect(x: curX - 4, y: runningY - 4, width: 8, height: 8))
            context.fill(redDot, with: .color(.red))
            context.stroke(redDot, with: .color(.white), lineWidth: 1.5)
        }

        // Green click preview + blue curve value at hover X
        if let hover, size.width > 0, size.height > 0 {
            let clampedX = max(0, min(size.width, hover.x))
            let clampedY = max(0, min(size.height, hover.y))
            let hoverTemp = (clampedX / size.width) * 90 + 20
            let profileSpeed = curve.speedForTemperature(hoverTemp)
            let profileY = size.height - (CGFloat(profileSpeed) / 100.0) * size.height

            var vLine = Path()
            vLine.move(to: CGPoint(x: clampedX, y: 0))
            vLine.addLine(to: CGPoint(x: clampedX, y: size.height))
            context.stroke(vLine, with: .color(.green.opacity(0.45)),
                         style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

            var hLine = Path()
            hLine.move(to: CGPoint(x: 0, y: clampedY))
            hLine.addLine(to: CGPoint(x: size.width, y: clampedY))
            context.stroke(hLine, with: .color(.green.opacity(0.35)),
                         style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

            // Blue: profile curve at hover temp (where green X meets blue curve)
            let blueDot = Path(ellipseIn: CGRect(x: clampedX - 4, y: profileY - 4, width: 8, height: 8))
            context.fill(blueDot, with: .color(.blue))
            context.stroke(blueDot, with: .color(.white), lineWidth: 1.5)

            // Green: click preview at mouse
            let greenDot = Path(ellipseIn: CGRect(x: clampedX - 4, y: clampedY - 4, width: 8, height: 8))
            context.fill(greenDot, with: .color(.green))
            context.stroke(greenDot, with: .color(.white), lineWidth: 1.5)
        }
    }

    @ViewBuilder
    private func curveHoverTooltip(size: CGSize) -> some View {
        let hover = curveHoverLocation ?? .zero
        let clampedX = max(0, min(size.width, hover.x))
        let clampedY = max(0, min(size.height, hover.y))
        let hoverTemp = max(20, min(110, (clampedX / max(size.width, 1)) * 90 + 20))
        let clickSpeed = max(0, min(100, (1 - clampedY / max(size.height, 1)) * 100))
        let currentTemp = sensorTemp(for: selectedSensorKey)
        let runningSpeed = fan.averageSpeedPercentage
        let profileSpeed = curve.speedForTemperature(hoverTemp)

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                ChartLineSwatch(color: .red, dashed: true)
                Text("Sensor").font(.system(size: 9)).foregroundStyle(.secondary)
                Text(String(format: "%.0f°C → %.0f%%", currentTemp, runningSpeed))
                    .font(.system(size: 9, weight: .medium, design: .rounded))
            }
            HStack(spacing: 5) {
                ChartLineSwatch(color: .blue)
                Text("Profile").font(.system(size: 9)).foregroundStyle(.secondary)
                Text(String(format: "%.0f°C → %.0f%%", hoverTemp, profileSpeed))
                    .font(.system(size: 9, weight: .medium, design: .rounded))
            }
            HStack(spacing: 5) {
                ChartLineSwatch(color: .green)
                Text("Click").font(.system(size: 9)).foregroundStyle(.secondary)
                Text(String(format: "%.0f°C → %.0f%%", hoverTemp, clickSpeed))
                    .font(.system(size: 9, weight: .medium, design: .rounded))
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        .fixedSize()
        .position(
            x: min(max(clampedX, 80), max(size.width - 80, 80)),
            y: 28
        )
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

    /// Clamps a dragged/typed temperature between its immediate neighbours so a point can never
    /// be moved past them and scramble the curve's order.
    private func constrainedTemperature(_ temp: Double, for id: UUID) -> Double {
        let sorted = curve.sortedPoints
        guard let index = sorted.firstIndex(where: { $0.id == id }) else {
            return max(Self.curveMinTemp, min(Self.curveMaxTemp, temp))
        }
        let lower = index > 0 ? sorted[index - 1].temperature + Self.minPointSpacing : Self.curveMinTemp
        let upper = index < sorted.count - 1 ? sorted[index + 1].temperature - Self.minPointSpacing : Self.curveMaxTemp
        guard lower <= upper else { return sorted[index].temperature }
        return max(lower, min(upper, temp))
    }

    private func handleDrag(value: DragGesture.Value, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }

        let temp = (value.location.x / size.width) * (Self.curveMaxTemp - Self.curveMinTemp) + Self.curveMinTemp
        let speed = (1 - value.location.y / size.height) * 100
        let clampedTemp = max(Self.curveMinTemp, min(Self.curveMaxTemp, temp))
        let clampedSpeed = max(0, min(100, speed))

        // Pick the grabbed point once, at the start of the gesture, and keep dragging that one —
        // otherwise sweeping past the curve mid-drag would grab or insert points by accident.
        if !isDraggingCurve {
            isDraggingCurve = true
            draggingPointID = pointID(near: value.location, size: size)
                ?? insertPointOnCurve(atTemperature: clampedTemp, location: value.location, size: size)
        }

        guard let id = draggingPointID else { return }
        curve.updatePoint(id: id,
                          temperature: constrainedTemperature(clampedTemp, for: id),
                          fanSpeed: clampedSpeed)
    }

    /// Nearest control point within the grab radius, measured in view space so the vertical
    /// distance counts too.
    private func pointID(near location: CGPoint, size: CGSize) -> UUID? {
        let candidates = curve.sortedPoints.map { point -> (UUID, CGFloat) in
            let position = canvasPosition(for: point, size: size)
            return (point.id, hypot(position.x - location.x, position.y - location.y))
        }
        guard let best = candidates.min(by: { $0.1 < $1.1 }), best.1 <= Self.pointGrabRadius else { return nil }
        return best.0
    }

    /// Clicking on the curve line itself inserts a control point there.
    private func insertPointOnCurve(atTemperature temp: Double, location: CGPoint, size: CGSize) -> UUID? {
        let speedOnCurve = curve.speedForTemperature(temp)
        let yOnCurve = size.height - (CGFloat(speedOnCurve) / 100.0) * size.height
        guard abs(yOnCurve - location.y) <= Self.lineGrabRadius else { return nil }

        // Don't stack a new point on top of an existing one.
        let tooClose = curve.sortedPoints.contains { point in
            abs(canvasPosition(for: point, size: size).x - location.x) < Self.minInsertDistance
                || abs(point.temperature - temp) < Self.minPointSpacing
        }
        guard !tooClose else { return nil }

        let point = CurvePoint(temperature: temp, fanSpeed: speedOnCurve)
        curve.addPoint(point)
        return point.id
    }

    private func canvasPosition(for point: CurvePoint, size: CGSize) -> CGPoint {
        let span = Self.curveMaxTemp - Self.curveMinTemp
        return CGPoint(
            x: ((point.temperature - Self.curveMinTemp) / span) * size.width,
            y: size.height - (CGFloat(point.fanSpeed) / 100.0) * size.height
        )
    }

    /// Splits the widest temperature gap, so a new point never lands on top of an existing one.
    private func addPoint() {
        let sorted = curve.sortedPoints
        guard sorted.count >= 2 else {
            let temp = (Self.curveMinTemp + Self.curveMaxTemp) / 2
            curve.addPoint(CurvePoint(temperature: temp, fanSpeed: curve.speedForTemperature(temp)))
            return
        }

        var widestIndex = 0
        var widestGap = -Double.infinity
        for i in 0..<(sorted.count - 1) {
            let gap = sorted[i + 1].temperature - sorted[i].temperature
            if gap > widestGap {
                widestGap = gap
                widestIndex = i
            }
        }

        let temp = (sorted[widestIndex].temperature + sorted[widestIndex + 1].temperature) / 2
        curve.addPoint(CurvePoint(temperature: temp, fanSpeed: curve.speedForTemperature(temp)))
    }

    private func removePoint(id: UUID) {
        if let idx = curve.points.firstIndex(where: { $0.id == id }) {
            curve.removePoint(at: idx)
        }
    }

    private func selectProfile(_ profile: FanProfile) {
        // Discard unsaved edits when switching cards.
        profileState.setSelectedProfile(profile)
        editingProfileMode = profile.mode
        hasUnsavedProfileChanges = false

        switch profile.mode {
        case .automatic:
            break
        case .manual:
            editingManualSpeed = profile.manualSpeedPercentage ?? 100
        case .curve:
            if let c = profile.curve {
                curve = c
                selectedSensorKey = c.sensorKey
            } else {
                curve = FanCurve(name: profile.name)
                selectedSensorKey = curve.sensorKey
            }
        }
    }

    /// Restores the selected profile to its factory default (built-in) or last saved values (custom).
    private func resetSelectedProfileToDefault() {
        guard let profile = profileState.selectedProfile else { return }

        let restored: FanProfile
        if let factory = FanProfile.builtInProfiles.first(where: { $0.name == profile.name }) {
            restored = FanProfile(
                id: profile.id,
                name: factory.name,
                mode: factory.mode,
                manualSpeedPercentage: factory.manualSpeedPercentage,
                curve: factory.curve,
                isBuiltIn: profile.isBuiltIn
            )
            let wasActive = profileState.activeProfile?.id == profile.id
            profileState.updateProfile(restored)
            selectProfile(restored)

            if wasActive {
                activateProfile(restored)
            }
        } else {
            // Custom profile: discard unsaved edits and reload last saved.
            selectProfile(profile)
        }
    }

    /// Saves edits into the selected profile without activating it.
    /// If that profile is already active, refresh live control to match the saved config.
    private func applySelectedProfileEdits() {
        guard var profile = profileState.selectedProfile else { return }

        switch editingProfileMode {
        case .automatic:
            profile.mode = .automatic
            profile.curve = nil
            profile.manualSpeedPercentage = nil
        case .manual:
            profile.mode = .manual
            profile.manualSpeedPercentage = editingManualSpeed
            profile.curve = nil
        case .curve:
            var savedCurve = curve
            savedCurve.sensorKey = selectedSensorKey
            savedCurve.name = profile.name
            profile.mode = .curve
            profile.curve = savedCurve
            profile.manualSpeedPercentage = nil
            curve = savedCurve
        }

        let wasActive = profileState.activeProfile?.id == profile.id
        profileState.updateProfile(profile)
        hasUnsavedProfileChanges = false

        // Refresh live control only if this profile is already active — do not activate.
        if wasActive {
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
                    fan.activeCurve = c
                    fan.controlMode = .curve
                    NotificationCenter.default.post(name: .fanControlModeChanged, object: FanControlMode.curve)
                }
            }
        }
    }

    private func activateProfile(_ profile: FanProfile) {
        // Shared activation, plus the editor-selection sync only this view needs.
        profileState.activate(profile, on: fan)
        selectProfile(profile)
        if let c = profile.curve {
            curve = c
            selectedSensorKey = c.sensorKey
        }
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
