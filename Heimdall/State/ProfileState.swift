import Foundation

// Fan profile storage. Previously declared inside ProfilesView.swift, which was
// otherwise dead UI; the state is live and belongs with the other state types.

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

    /// Renames a custom profile. Built-ins are not renameable.
    func renameProfile(_ profile: FanProfile, to newName: String) {
        guard !profile.isBuiltIn else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != profile.name else { return }
        var updated = profile
        updated.name = trimmed
        if var curve = updated.curve {
            curve.name = trimmed
            updated.curve = curve
        }
        updateProfile(updated)
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
