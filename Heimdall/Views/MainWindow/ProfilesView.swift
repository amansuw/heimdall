import SwiftUI

@Observable
class ProfileState {
    var profiles: [FanProfile] = FanProfile.builtInProfiles
    var activeProfile: FanProfile?
    var selectedProfile: FanProfile?
    var customCurve: FanCurve?

    private static let customProfilesKey = "heimdall.customProfiles"
    private static let builtInOverridesKey = "heimdall.builtInProfileOverrides"

    var latestCustomProfile: FanProfile? {
        profiles.last(where: { !$0.isBuiltIn })
    }

    func profile(named name: String) -> FanProfile? {
        profiles.first(where: { $0.name == name })
    }

    /// Default, Silent, Performance, and the latest custom profile (when present).
    var menuBarProfiles: [FanProfile] {
        var items = ["Default", "Silent", "Performance"].compactMap { profile(named: $0) }
        if let latest = latestCustomProfile {
            items.append(latest)
        }
        return items
    }

    func setActiveProfile(_ profile: FanProfile?) {
        activeProfile = profile
    }

    func setSelectedProfile(_ profile: FanProfile?) {
        selectedProfile = profile
    }

    func addCustomProfile(_ profile: FanProfile) {
        profiles.append(profile)
        saveProfiles()
    }

    /// Updates an existing profile (built-in or custom) in place. Does not change which profile is active.
    func updateProfile(_ profile: FanProfile) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[idx] = profile
        if activeProfile?.id == profile.id {
            activeProfile = profile
        }
        if selectedProfile?.id == profile.id {
            selectedProfile = profile
        }
        saveProfiles()
    }

    func removeProfile(_ profile: FanProfile) {
        guard !profile.isBuiltIn else { return }
        profiles.removeAll { $0.id == profile.id }
        if activeProfile?.id == profile.id { activeProfile = nil }
        if selectedProfile?.id == profile.id { selectedProfile = nil }
        saveProfiles()
    }

    private func saveProfiles() {
        let custom = profiles.filter { !$0.isBuiltIn }
        if let data = try? JSONEncoder().encode(custom) {
            UserDefaults.standard.set(data, forKey: Self.customProfilesKey)
        }

        // Persist built-in edits keyed by name (built-in UUIDs are session-stable only).
        let factoryByName = Dictionary(uniqueKeysWithValues: FanProfile.builtInProfiles.map { ($0.name, $0) })
        let overrides = profiles.filter { profile in
            guard profile.isBuiltIn, let factory = factoryByName[profile.name] else { return false }
            return profile.mode != factory.mode
                || profile.manualSpeedPercentage != factory.manualSpeedPercentage
                || profile.curve != factory.curve
        }
        if overrides.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.builtInOverridesKey)
        } else if let data = try? JSONEncoder().encode(overrides) {
            UserDefaults.standard.set(data, forKey: Self.builtInOverridesKey)
        }
    }

    func loadProfiles() {
        var builtIns = FanProfile.builtInProfiles

        if let data = UserDefaults.standard.data(forKey: Self.builtInOverridesKey),
           let overrides = try? JSONDecoder().decode([FanProfile].self, from: data) {
            for override in overrides {
                guard let idx = builtIns.firstIndex(where: { $0.name == override.name }) else { continue }
                let factoryID = builtIns[idx].id
                builtIns[idx] = FanProfile(
                    id: factoryID,
                    name: override.name,
                    mode: override.mode,
                    manualSpeedPercentage: override.manualSpeedPercentage,
                    curve: override.curve,
                    isBuiltIn: true
                )
            }
        }

        var custom: [FanProfile] = []
        if let data = UserDefaults.standard.data(forKey: Self.customProfilesKey),
           let decoded = try? JSONDecoder().decode([FanProfile].self, from: data) {
            custom = decoded
        }

        profiles = builtIns + custom
    }
}

struct ProfilesView: View {
    @Environment(ProfileState.self) private var profileState
    @Environment(FanState.self) private var fan
    @State private var showingNewProfile = false
    @State private var newProfileName = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HStack {
                    Text("Profiles").font(.largeTitle).fontWeight(.bold)
                    Spacer()
                    Button(action: { showingNewProfile = true }) {
                        Label("New Profile", systemImage: "plus")
                    }
                }
                .padding(.horizontal)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(profileState.profiles, id: \.id) { profile in
                        ProfileCard(profile: profile,
                                    isActive: profileState.activeProfile?.id == profile.id,
                                    onActivate: { activateProfile(profile) },
                                    onDelete: profile.isBuiltIn ? nil : { profileState.removeProfile(profile) })
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showingNewProfile) {
            VStack(spacing: 16) {
                Text("New Profile").font(.headline)
                TextField("Profile Name", text: $newProfileName)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Cancel") { showingNewProfile = false }
                    Button("Create") {
                        let profile = FanProfile(name: newProfileName, mode: .automatic)
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

    private func activateProfile(_ profile: FanProfile) {
        profileState.setActiveProfile(profile)

        switch profile.mode {
        case .automatic:
            NotificationCenter.default.post(name: .fanControlModeChanged, object: FanControlMode.automatic)
        case .manual:
            if let speed = profile.manualSpeedPercentage {
                fan.manualSpeedPercentage = speed
                NotificationCenter.default.post(name: .fanControlModeChanged, object: FanControlMode.manual)
            }
        case .curve:
            if let curve = profile.curve {
                fan.activeCurve = curve
                NotificationCenter.default.post(name: .fanControlModeChanged, object: FanControlMode.curve)
            }
        }
    }
}

struct ProfileCard: View {
    let profile: FanProfile
    let isActive: Bool
    let onActivate: () -> Void
    let onDelete: (() -> Void)?

    private var modeIcon: String {
        switch profile.mode {
        case .automatic: return "gearshape"
        case .manual: return "slider.horizontal.3"
        case .curve: return "chart.xyaxis.line"
        }
    }

    private var profileColor: Color {
        switch profile.name {
        case "Silent": return .blue
        case "Default": return .green
        case "Balanced": return .yellow
        case "Performance": return .orange
        case "Max": return .red
        default: return .purple
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(profileColor).frame(width: 10, height: 10)
                Text(profile.name).font(.headline)
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            HStack {
                Image(systemName: modeIcon).font(.caption).foregroundStyle(.secondary)
                Text(profile.mode.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                if let speed = profile.manualSpeedPercentage {
                    Text("· \(Int(speed))%").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(isActive ? "Active" : "Activate") { onActivate() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isActive)
                Spacer()
                if let onDelete {
                    Button(action: onDelete) {
                        Image(systemName: "trash").foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                }
            }
        }
        .padding()
        .background(
            isActive ? Color.accentColor.opacity(0.05) : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isActive ? Color.accentColor : .clear, lineWidth: 1.5)
        )
    }
}
