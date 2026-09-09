# Homebrew cask for Heimdall.
#
# This repository doubles as its own Homebrew tap, because Homebrew will read a
# top-level Casks/ directory out of any repo you tap by explicit URL:
#
#   brew tap amansuw/heimdall https://github.com/amansuw/heimdall
#   brew install --cask --no-quarantine amansuw/heimdall/heimdall
#
# --no-quarantine matters. Heimdall is ad-hoc signed and cannot be notarized
# (no paid Apple Developer account), so a normal `brew install --cask` would
# stamp com.apple.quarantine onto the app and you would hit the same Gatekeeper
# wall as a manual DMG download. Passing --no-quarantine tells Homebrew not to
# apply that attribute, which is the whole reason the Homebrew path is smoother
# than the DMG path. You are trusting the tap instead of Apple; the README
# explains how to verify the download before you do.
#
# RELEASING: bump `version` and replace `sha256` with the value from the
# SHA256SUMS.txt asset attached to the matching GitHub Release.

cask "heimdall" do
  version "1.2"

  # REPLACE ON EVERY RELEASE. Copy from the release's SHA256SUMS.txt, or run:
  #   shasum -a 256 Heimdall-<version>.dmg
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/amansuw/heimdall/releases/download/v#{version}/Heimdall-#{version}.dmg",
      verified: "github.com/amansuw/heimdall/"
  name "Heimdall"
  desc "Menu bar system monitor with SMC sensor readout and fan control"
  homepage "https://github.com/amansuw/heimdall"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sequoia"

  app "Heimdall.app"

  # `brew uninstall` path: stop the app and the root helper, then remove the
  # helper's plist and runtime files. Without this, uninstalling the cask would
  # leave a root LaunchDaemon loaded and running with no app to drive it.
  uninstall quit:      "com.heimdall.app",
            launchctl: "com.heimdall.smchelper",
            delete:    [
              "/Library/LaunchDaemons/com.heimdall.smchelper.plist",
              "/var/run/heimdall",
              "/var/log/heimdall-daemon.log",
            ]

  # `brew uninstall --zap` path: everything above plus per-user state, and a
  # second pass over the system paths so a zap still cleans up after a
  # half-finished manual removal.
  zap launchctl: "com.heimdall.smchelper",
      delete:    [
        "/Library/LaunchDaemons/com.heimdall.smchelper.plist",
        "/var/run/heimdall",
        "/var/log/heimdall-daemon.log",
        # Runtime files used by older builds.
        "/tmp/heimdall-smc-cmd",
        "/tmp/heimdall-smc-rsp",
        "/tmp/heimdall-smc-ready",
        "/tmp/heimdall-daemon.log",
      ],
      trash:     [
        "~/Library/Caches/com.heimdall.app",
        "~/Library/HTTPStorages/com.heimdall.app",
        "~/Library/HTTPStorages/com.heimdall.app.binarycookies",
        "~/Library/Preferences/com.heimdall.app.plist",
        "~/Library/Saved Application State/com.heimdall.app.savedState",
      ]

  caveats <<~EOS
    Heimdall is ad-hoc signed and is not notarized by Apple, because the project
    has no paid Apple Developer account.

    If you installed WITHOUT --no-quarantine, macOS will refuse the first launch.
    Either reinstall with:

      brew reinstall --cask --no-quarantine heimdall

    or approve it once in System Settings > Privacy & Security > "Open Anyway".

    Heimdall is a menu bar app, so nothing opens on launch except an icon at the
    top of your screen.

    Fan control needs a small root helper (com.heimdall.smchelper) that talks to
    the System Management Controller. Heimdall asks for your admin password the
    first time you use fan control, and never again. To remove the helper along
    with everything else:

      brew uninstall --zap --cask heimdall
  EOS
end
