import SwiftUI

@Observable
class ProfileState {
    var profiles: [FanProfile] = FanProfile.builtInProfiles
    var activeProfile: FanProfile?
    var customCurve: FanCurve?

    var latestCustomProfile: FanProfile? {
        profiles.first(where: { !$0.isBuiltIn })
    }

    func setActiveProfile(_ profile: FanProfile) {
        activeProfile = profile
    }

    func addCustomProfile(_ profile: FanProfile) {
        profiles.append(profile)
        saveProfiles()
    }

    func removeProfile(_ profile: FanProfile) {
        guard !profile.isBuiltIn else { return }
        profiles.removeAll { $0.id == profile.id }
        if activeProfile?.id == profile.id { activeProfile = nil }
        saveProfiles()
    }

    private func saveProfiles() {
        let custom = profiles.filter { !$0.isBuiltIn }
        if let data = try? JSONEncoder().encode(custom) {
            UserDefaults.standard.set(data, forKey: "heimdall.customProfiles")
        }
    }

    func loadProfiles() {
        if let data = UserDefaults.standard.data(forKey: "heimdall.customProfiles"),
           let custom = try? JSONDecoder().decode([FanProfile].self, from: data) {
            profiles = FanProfile.builtInProfiles + custom
        }
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
