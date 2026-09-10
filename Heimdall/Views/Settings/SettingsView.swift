import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        TabView {
            Form {
                Section {
                    Toggle("Open Heimdall at login", isOn: $settings.launchAtLogin)
                    if let error = settings.launchAtLoginError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } footer: {
                    Text("Heimdall lives in the menu bar. Opening at login keeps monitoring continuous.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker("Menu bar shows", selection: $settings.menuBarDisplay) {
                        ForEach(MenuBarDisplay.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    Picker("Temperature", selection: $settings.temperatureUnit) {
                        ForEach(TemperatureUnit.allCases) { unit in
                            Text(unit.label).tag(unit)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            FanHelperSettings()
                .tabItem { Label("Fan Control", systemImage: "fan.fill") }

            DiagnosticsSettings()
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .frame(width: 460, height: 320)
    }
}

/// Explains the privileged helper and offers a way out of it. Users are asked for
/// an admin password to install a root daemon, so the app should be able to say
/// plainly what that is and how to remove it.
private struct FanHelperSettings: View {
    @Environment(FanState.self) private var fan
    @State private var showRemoveConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: fan.hasWriteAccess ? "checkmark.seal.fill" : "lock.fill")
                    .foregroundStyle(fan.hasWriteAccess ? .green : .secondary)
                Text(fan.hasWriteAccess ? "Fan control is enabled" : "Fan control is not enabled")
                    .font(.headline)
            }

            Text("""
                 Reading sensors needs no special access. Changing fan speeds does: \
                 macOS only lets a root process write to the System Management \
                 Controller, so Heimdall installs a small helper (\(SMCDaemon.daemonLabel)) \
                 and talks to it over a local socket. The helper accepts only fan-related \
                 SMC keys, and only from Heimdall itself.
                 """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !fan.hasWriteAccess {
                Button("Enable Fan Control…") {
                    NotificationCenter.default.post(name: .requestFanAccess, object: nil)
                }
                .buttonStyle(.borderedProminent)
            }

            Spacer()

            Button("Remove Helper…", role: .destructive) { showRemoveConfirmation = true }
                .confirmationDialog(
                    "Remove the fan control helper?",
                    isPresented: $showRemoveConfirmation
                ) {
                    Button("Show Me How", role: .none) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
                    }
                } message: {
                    Text("""
                         Run scripts/uninstall.sh from the Heimdall repository, or:
                         sudo launchctl bootout system/\(SMCDaemon.daemonLabel)
                         sudo rm \(SMCDaemon.plistPath)

                         Fans return to automatic control immediately.
                         """)
                }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


/// Heimdall is developed on one Mac. A diagnostics dump from someone else's
/// machine is the practical way to fix sensors, fans or core layout on hardware
/// the author cannot test.
private struct DiagnosticsSettings: View {
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Report a hardware problem").font(.headline)

            Text("""
                 If sensors, fans or CPU cores look wrong on your Mac, copy this                  report into a GitHub issue. It lists your CPU cluster layout, GPU                  core count and every SMC key with its raw bytes — the raw bytes are                  what make it possible to reproduce and fix a decoding bug without                  owning your machine.

                 It contains no personal data: no file names, no network addresses,                  no account details.
                 """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(copied ? "Copied" : "Copy Diagnostics") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Diagnostics.report(), forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                }
                .buttonStyle(.borderedProminent)

                Button("Open Issue Tracker") {
                    if let url = URL(string: "https://github.com/amansuw/heimdall/issues/new?template=hardware-report.md") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
